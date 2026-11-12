"""The `setup` verb: make a machine and a repo ready.

One command, four artifacts, and no ceremony:

1. **The store** — created when absent (`create` policy), never migrated:
   a damaged, foreign, older or newer file is named and left exactly as
   found.
2. **The post-merge hook** — written only into the repository's *common*
   hooks directory, so a linked worktree shares the one hook git actually
   runs. The file carries an ownership marker comment; a `post-merge`
   without that marker is refused by name and never overwritten.
   `--remove-hook` removes only a marked hook.
3. **The report directory** — `<repo>/.skill-log/reports/` with its README
   and keep file. Files already there are left byte-for-byte alone.
4. **The skills verdict** — the document classification over
   `--skills-dir`, the same one `skills audit` gives, so the two commands
   can never disagree.

## A thin coordinator

Each artifact is asked for its own verdict (`store.verify`, the hook
marker, the directory's files, the document classification); `setup`
does not know their formats and there is no uniform provisioner
interface — only the verdict struct below. A verdict is one of the five
statuses the JSON contract names (`created`, `updated`, `unchanged`,
`drift`, `skipped`) plus a detail that names its reason. Any drift is
the run's failure: the first one is the one stderr line, and the exit
code is 1.

`--check` is the same verdicts with every write turned off: drift means
"this is not set up", and nothing on disk moves. `--dry-run` shows what
a real run would change, in the same shape.

## The generated hook

The hook resolves the CLI at run time (`command -v skill-log`; `mise
which skill-log` when mise is on `PATH`; the mise shim under `$HOME`;
else exit 0 silently), derives the pre-merge position from the reflog,
and wraps the call so a missing, older or failing CLI never changes the
pull's exit status — the hook itself always exits 0 and writes nothing.

## Skips

A checkout that is not a git repository skips the two repo-scoped
artifacts with a named reason and exits 0; the machine-scoped store is
still created. `--no-hook` and `--no-report-dir` turn one artifact off
the same way.
"""

from std.os import makedirs, remove
from std.pathlib import Path

from skill_log.context import hostname
from skill_log.detect import git_common_dir, git_toplevel, git_toplevel_of
from skill_log.document import STATE_OK, STATE_VENDORED, render
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.files import read_text, write_text, write_text_mode
from skill_log.flags import take_value
from skill_log.json import json_string
from skill_log.report import (
    KEEP_NAME,
    README_NAME,
    REPORT_DIR,
    report_dir_readme,
)
from skill_log.skills import (
    Template,
    audit_skill,
    load_template,
    resolve_template_dir,
    skill_dirs,
    validate_effective,
)
from skill_log.store import expand_home, open_write, resolve_db, verify
from skill_log.templates import USAGE_LOG_NAME

# The ownership marker every generated hook carries, on a line of its
# own. It is the one thing that says "this tool wrote this file": the
# marker decides whether a `post-merge` may be replaced or removed, and
# a file without it is never touched.
comptime HOOK_MARKER = "# skill-log:post-merge-hook"

# The hook's name inside the repository's common hooks directory.
comptime HOOK_NAME = "post-merge"

# The mode the generated hook is written with: git runs a hook only when
# it is executable, so the file carries its execute bits at creation and
# no umask can narrow them.
comptime HOOK_MODE = 493  # 0755

# The artifact names, in the order every output lists them (SPEC §5.10).
comptime ARTIFACT_STORE = "store"
comptime ARTIFACT_HOOK = "hook"
comptime ARTIFACT_REPORT_DIR = "report_dir"
comptime ARTIFACT_SKILLS = "skills"

# The verdict statuses (SPEC §5.10). `drift` is the one that fails the
# run: under `--check` it means "not set up", otherwise it means "this
# run refused to change it".
comptime STATUS_CREATED = "created"
comptime STATUS_UPDATED = "updated"
comptime STATUS_UNCHANGED = "unchanged"
comptime STATUS_DRIFT = "drift"
comptime STATUS_SKIPPED = "skipped"


# --------------------------------------------------------------- options


struct Options(Movable):
    """The flags `setup` accepts."""

    var repo: String
    var skills_dir: String
    var db: String
    var json: Bool
    var dry_run: Bool
    var check: Bool
    var force: Bool
    var remove_hook: Bool
    var no_hook: Bool
    var no_report_dir: Bool

    def __init__(out self):
        self.repo = ""
        self.skills_dir = ""
        self.db = ""
        self.json = False
        self.dry_run = False
        self.check = False
        self.force = False
        self.remove_hook = False
        self.no_hook = False
        self.no_report_dir = False


def parse_options(args: List[String]) raises -> Options:
    """Read `setup`'s flags.

    An unknown flag, a missing value or a contradictory pair is a usage
    error, raised as a `usage` marker the caller turns into exit 2.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--repo":
            options.repo = take_value(args, i, "--repo", "a directory")
            i += 1
        elif arg == "--skills-dir":
            options.skills_dir = take_value(
                args, i, "--skills-dir", "a directory"
            )
            i += 1
        elif arg == "--db":
            options.db = take_value(args, i, "--db", "a path")
            i += 1
        elif arg == "--json":
            options.json = True
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--check":
            options.check = True
        elif arg == "--force":
            options.force = True
        elif arg == "--remove-hook":
            options.remove_hook = True
        elif arg == "--no-hook":
            options.no_hook = True
        elif arg == "--no-report-dir":
            options.no_report_dir = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    # Two modes that say opposite things about the hook cannot be one
    # run. The pair is refused before anything is examined.
    if options.check and options.remove_hook:
        raise Error(
            "usage: --check verifies and --remove-hook removes; pick one"
        )
    if options.remove_hook and options.no_hook:
        raise Error(
            "usage: --remove-hook and --no-hook cannot be combined"
        )

    return options^


# ------------------------------------------------------------ hook text


def hook_script() -> String:
    """The post-merge hook `setup` writes.

    It resolves the CLI at run time — `command -v skill-log`, then
    `mise which skill-log` when mise is on `PATH`, then the mise shim
    under `$HOME`, then nothing (exit 0 silently) — derives the pre-merge
    position from the reflog, and calls `resolve-merged` quietly. Every
    failure is swallowed: a pull's exit status is git's alone, and the
    hook writes nothing at all.
    """
    return """\
#!/bin/sh
# skill-log:post-merge-hook
#
# Installed by skill-log setup; removed by skill-log setup --remove-hook.
# Resolves the rows a pull landed. It never changes the pull's exit
# status: a missing, older or failing skill-log is skipped silently, and
# nothing here writes to stderr.

cli=
if command -v skill-log >/dev/null 2>&1; then
    cli=$(command -v skill-log)
fi
if [ -z "$cli" ] && command -v mise >/dev/null 2>&1; then
    cli=$(mise which skill-log 2>/dev/null)
fi
if [ -z "$cli" ] && [ -x "$HOME/.local/share/mise/shims/skill-log" ]; then
    cli="$HOME/.local/share/mise/shims/skill-log"
fi
[ -n "$cli" ] || exit 0

since=$(git rev-parse --verify -q 'HEAD@{1}' 2>/dev/null)
if [ -n "$since" ]; then
    "$cli" resolve-merged --since "$since" --quiet >/dev/null 2>&1
else
    "$cli" resolve-merged --quiet >/dev/null 2>&1
fi

exit 0
"""


def has_ownership_marker(text: String) -> Bool:
    """True when `text` carries the ownership marker at a line start.

    The marker is a comment line, so prose that merely mentions it (at
    a line start with more words around it) still counts as carrying it —
    the marker's job is to say who wrote the file, and an edited copy of
    our own hook is still ours to replace.
    """
    var n = text.byte_length()
    var start = 0
    while start <= n:
        if text.find(HOOK_MARKER, start) == start:
            return True
        var end = text.find("\n", start)
        if end < 0:
            return False
        start = end + 1
    return False


# ------------------------------------------------------------- verdicts


struct Verdict(Movable):
    """One artifact's verdict: its name, what happened, and why.

    This is the whole interface between `setup` and the owners of its
    artifacts — there is no provisioner type behind it (ADR-0003).
    """

    var artifact: String
    var status: String
    var detail: String

    def __init__(
        out self,
        artifact: String = "",
        status: String = "",
        detail: String = "",
    ):
        self.artifact = artifact
        self.status = status
        self.detail = detail


def verdict_line(verdict: Verdict) -> String:
    """One human line: the status, the artifact, the detail."""
    return verdict.status + "  " + verdict.artifact + "  " + verdict.detail


def verdict_json(verdict: Verdict) -> String:
    """One JSON object, exactly `artifact`, `status`, `detail` (§5.10)."""
    return (
        "{\"artifact\":"
        + json_string(verdict.artifact)
        + ",\"status\":"
        + json_string(verdict.status)
        + ",\"detail\":"
        + json_string(verdict.detail)
        + "}"
    )


def store_verdict(path: String, check: Bool, dry_run: Bool) raises -> Verdict:
    """The store's verdict: `create`, or `verify` under `--check`.

    The verdict comes from the store's own path — `verify` for the read
    and `open_write` for the creation — and never from inspecting SQLite
    here. A refused store is drift with the refusal's own named message:
    setup creates a store and never migrates one.
    """
    var found = verify(path)
    if found.ok():
        return Verdict(ARTIFACT_STORE, STATUS_UNCHANGED, path)
    if found.refusal.refused():
        return Verdict(
            ARTIFACT_STORE, STATUS_DRIFT, found.refusal.failure().message
        )
    if check:
        return Verdict(ARTIFACT_STORE, STATUS_DRIFT, "no store at " + path)
    if dry_run:
        return Verdict(ARTIFACT_STORE, STATUS_CREATED, path)
    var opened = open_write(path)
    if opened.refusal.refused():
        # The file appeared between the verdict and the creation, and it
        # is not a store we may use.
        return Verdict(
            ARTIFACT_STORE, STATUS_DRIFT, opened.refusal.failure().message
        )
    return Verdict(ARTIFACT_STORE, STATUS_CREATED, path)


def hook_verdict(common: String, options: Options) raises -> Verdict:
    """The post-merge hook's verdict in the common hooks directory.

    The hook goes where git runs hooks for every checkout of the
    repository — `git rev-parse --git-common-dir`/hooks — never a linked
    worktree's own directory.
    """
    if common == "":
        return Verdict(ARTIFACT_HOOK, STATUS_SKIPPED, "not a git checkout")
    if options.remove_hook:
        return remove_hook_verdict(hook_path(common), options.dry_run)
    if options.no_hook:
        return Verdict(
            ARTIFACT_HOOK, STATUS_SKIPPED, "hook disabled by --no-hook"
        )

    var path = hook_path(common)
    var wanted = hook_script()
    if Path(path).is_file():
        var text = read_text(path)
        if not has_ownership_marker(text):
            # Never overwrite a file this tool did not write: the marker
            # is the ownership claim, and without it the file is refused
            # by name.
            return Verdict(
                ARTIFACT_HOOK,
                STATUS_DRIFT,
                "the post-merge hook at "
                + path
                + " carries no ownership marker",
            )
        if text == wanted:
            return Verdict(ARTIFACT_HOOK, STATUS_UNCHANGED, path)
        if options.check:
            return Verdict(
                ARTIFACT_HOOK,
                STATUS_DRIFT,
                "the post-merge hook at "
                + path
                + " differs from this version's hook",
            )
        if options.dry_run:
            return Verdict(ARTIFACT_HOOK, STATUS_UPDATED, path)
        write_text_mode(path, wanted, HOOK_MODE)
        return Verdict(ARTIFACT_HOOK, STATUS_UPDATED, path)

    if options.check:
        return Verdict(
            ARTIFACT_HOOK, STATUS_DRIFT, "no post-merge hook at " + path
        )
    if options.dry_run:
        return Verdict(ARTIFACT_HOOK, STATUS_CREATED, path)
    makedirs(common + "/hooks", exist_ok=True)
    write_text_mode(path, wanted, HOOK_MODE)
    return Verdict(ARTIFACT_HOOK, STATUS_CREATED, path)


def hook_path(common: String) -> String:
    """The hook's path inside the common hooks directory."""
    return common + "/hooks/" + HOOK_NAME


def remove_hook_verdict(path: String, dry_run: Bool) raises -> Verdict:
    """`--remove-hook`: remove the marked hook, and only that.

    A file without the marker is not ours to remove, so it is left
    exactly as found and named as skipped. Nothing else is touched.
    """
    if not Path(path).is_file():
        return Verdict(
            ARTIFACT_HOOK, STATUS_UNCHANGED, "no post-merge hook at " + path
        )
    var text = read_text(path)
    if not has_ownership_marker(text):
        return Verdict(
            ARTIFACT_HOOK,
            STATUS_SKIPPED,
            "left alone: " + path + " carries no ownership marker",
        )
    if dry_run:
        return Verdict(ARTIFACT_HOOK, STATUS_UPDATED, "removed " + path)
    remove(path)
    return Verdict(ARTIFACT_HOOK, STATUS_UPDATED, "removed " + path)


def report_dir_verdict(repo: String, options: Options) raises -> Verdict:
    """The report directory's verdict.

    The directory is created with its README and keep file and nothing
    else. A file already present is written by no one: the README is the
    operator's to edit and the report files are the transport, so both
    are left byte-for-byte alone and only a missing piece is added.
    """
    if repo == "":
        return Verdict(
            ARTIFACT_REPORT_DIR, STATUS_SKIPPED, "not a git checkout"
        )
    if options.no_report_dir:
        return Verdict(
            ARTIFACT_REPORT_DIR,
            STATUS_SKIPPED,
            "report directory disabled by --no-report-dir",
        )

    var dir = repo + "/" + REPORT_DIR
    var readme = dir + "/" + README_NAME
    var keep = dir + "/" + KEEP_NAME

    var dir_there = Path(dir).is_dir()
    var readme_there = Path(readme).is_file()
    var keep_there = Path(keep).is_file()

    if dir_there and readme_there and keep_there:
        return Verdict(ARTIFACT_REPORT_DIR, STATUS_UNCHANGED, dir)

    if options.check:
        if not dir_there:
            return Verdict(
                ARTIFACT_REPORT_DIR,
                STATUS_DRIFT,
                "no report directory at " + dir,
            )
        if not readme_there:
            return Verdict(
                ARTIFACT_REPORT_DIR, STATUS_DRIFT, "no README at " + readme
            )
        return Verdict(
            ARTIFACT_REPORT_DIR, STATUS_DRIFT, "no keep file at " + keep
        )

    var status = STATUS_UPDATED
    if not dir_there:
        status = STATUS_CREATED
    if options.dry_run:
        return Verdict(ARTIFACT_REPORT_DIR, status, dir)
    if not dir_there:
        makedirs(dir, exist_ok=True)
    if not readme_there:
        write_text(readme, report_dir_readme())
    if not keep_there:
        write_text(keep, "")
    return Verdict(ARTIFACT_REPORT_DIR, status, dir)


def skills_verdict(skills_dir: String) raises -> Verdict:
    """The installed skills' verdict: the document classification.

    It is the same classification `skills audit` reports, over
    `--skills-dir`, so a directory an audit calls clean is one `setup
    --check` calls clean. Without `--skills-dir` there is nothing to
    classify and the artifact is skipped with that named reason.
    """
    if String(skills_dir.strip()) == "":
        return Verdict(
            ARTIFACT_SKILLS, STATUS_SKIPPED, "no --skills-dir given"
        )
    var dir = String(expand_home(String(skills_dir.strip())))
    if not Path(dir).is_dir():
        return Verdict(
            ARTIFACT_SKILLS, STATUS_SKIPPED, dir + " is not a directory"
        )
    var names = skill_dirs(dir)
    if len(names) == 0:
        return Verdict(
            ARTIFACT_SKILLS, STATUS_SKIPPED, "no skills in " + dir
        )

    # The current render is what the fences are compared against; a
    # template that cannot be rendered is drift with its own named
    # message rather than a crash in the middle of a setup run.
    var template: Template
    try:
        template = load_template(USAGE_LOG_NAME, resolve_template_dir(""))
        validate_effective(USAGE_LOG_NAME, template)
    except e:
        return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, String(e))
    var rendered = render(template.content, "skill", "skill-log")

    var bad = List[String]()
    for i in range(len(names)):
        var item = audit_skill(
            dir, names[i], rendered.template_hash, rendered.content_hash
        )
        if item.state != STATE_OK and item.state != STATE_VENDORED:
            bad.append(item.skill + ":" + item.state)

    if len(bad) == 0:
        return Verdict(
            ARTIFACT_SKILLS,
            STATUS_UNCHANGED,
            String(len(names)) + " skills conform",
        )
    var detail = String("")
    for i in range(len(bad)):
        if i > 0:
            detail += ", "
        detail += bad[i]
    return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, detail)


# --------------------------------------------------------------- help


def setup_usage() -> String:
    """The usage line, as `--help` shows it."""
    return "skill-log setup [--repo <dir>] [--skills-dir <dir>] [--db <path>]\n" \
           "                [--check] [--dry-run] [--json] [--force]\n" \
           "                [--remove-hook] [--no-hook] [--no-report-dir]"


def setup_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them."""
    var examples = List[String]()
    examples.append("skill-log setup")
    examples.append("skill-log setup --repo ~/src/myrepo --check")
    examples.append("skill-log setup --dry-run --json")
    examples.append("skill-log setup --remove-hook")
    return examples^


def setup_value_flags() -> List[String]:
    """The flags that consume the next argument."""
    var flags = List[String]()
    flags.append("--repo")
    flags.append("--skills-dir")
    flags.append("--db")
    return flags^


def setup_notes() -> String:
    """The paragraph between the usage line and the examples."""
    return "One command makes a machine and a repo ready: the store, the git\n" \
           "post-merge hook that resolves what a pull landed, and the report\n" \
           "directory (.skill-log/reports/ with its README and keep file). It\n" \
           "prints the machine identity the log will use, so the spelling\n" \
           "every marker must match is visible. Re-running is a no-op.\n" \
           "\n" \
           "The hook goes only into the repository's common hooks directory\n" \
           "(git rev-parse --git-common-dir), so a linked worktree shares one\n" \
           "hook. A post-merge without the ownership marker is refused by\n" \
           "name and never overwritten; --remove-hook removes only a marked\n" \
           "hook. The hook resolves the CLI at run time and never changes a\n" \
           "pull's exit status.\n" \
           "\n" \
           "--check verifies the store, the hook, the report directory and\n" \
           "the skills under --skills-dir instead of writing, and exits 1 on\n" \
           "drift. --dry-run shows what a real run would change. A store\n" \
           "written by another schema is named and left alone: setup creates\n" \
           "a store and never migrates one.\n" \
           "\n" \
           "--no-hook and --no-report-dir turn one artifact off; --force\n" \
           "applies to the skills install. A directory that is not a git\n" \
           "checkout is skipped with a named reason, exit 0."


# -------------------------------------------------------------- handler


def resolve_repo(flag: String) -> String:
    """The checkout `setup` works on: `--repo`, else this checkout.

    Either way the answer is the git toplevel — the root the report
    directory and the hook belong to. An empty answer means no git
    checkout, and the repo-scoped artifacts are skipped with a named
    reason rather than failing.
    """
    if String(flag.strip()) != "":
        return git_toplevel_of(expand_home(String(flag.strip())))
    return git_toplevel()


def handle_setup(args: List[String]) raises -> Outcome:
    """The `setup` handler.

    Returns the text to print on stdout (plus the failure to report), or
    the failure alone. It never prints and never exits: `main` owns both.
    """
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    # The machine identity the log will use, printed every run: the
    # hostname spelling is what every marker must match.
    var machine = String("")
    try:
        machine = hostname()
    except e:
        return Outcome.fail(String(e), EXIT_FAILURE())

    var repo = resolve_repo(options.repo)
    var common = ""
    if repo != "":
        common = git_common_dir(repo)

    var path = resolve_db(options.db)

    # The four verdicts, in the order the JSON contract lists them. Each
    # owner answers for its own artifact; nothing here inspects a
    # format.
    var verdicts = List[Verdict]()
    verdicts.append(store_verdict(path, options.check, options.dry_run))
    verdicts.append(hook_verdict(common, options))
    verdicts.append(report_dir_verdict(repo, options))
    verdicts.append(skills_verdict(options.skills_dir))

    var text = String("")
    if options.json:
        for i in range(len(verdicts)):
            if i > 0:
                text += "\n"
            text += verdict_json(verdicts[i])
    else:
        text = "machine: " + machine
        for i in range(len(verdicts)):
            text += "\n" + verdict_line(verdicts[i])

    # Any drift is the run's failure. The first one is the one stderr
    # line; the artifact lines carry every verdict.
    for i in range(len(verdicts)):
        if verdicts[i].status == STATUS_DRIFT:
            var outcome = Outcome.fail(verdicts[i].detail, EXIT_FAILURE())
            outcome.text = text
            return outcome^

    return Outcome.ok(text)