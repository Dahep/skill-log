"""The `setup` verb: make a machine and a repo ready."""

from std.os import makedirs, remove
from std.pathlib import Path

from skill_log.bundled import (
    REVIEW_SKILL,
    SKILL_LOG_SKILL,
    review_document,
    skill_log_document,
    stamp_version,
)
from skill_log.context import hostname
from skill_log.git import git_common_dir, git_toplevel
from skill_log.document import is_vendored
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.files import (
    is_executable,
    read_text,
    set_executable,
    write_text,
    write_text_mode,
)
from skill_log.flags import take_declared_value
from skill_log.json import JsonObject
from skill_log.report import (
    KEEP_NAME,
    README_NAME,
    REPORT_DIR,
    report_dir_readme,
)
from skill_log.settings import (
    expand_home,
    resolve_db,
    resolve_template_dir,
    resolved_command,
)
from skill_log.skills import (
    Template,
    load_template,
    moved_default_note,
    validate_effective,
)
from skill_log.store import (
    open_write,
    verify,
    write_failure,
)
from skill_log.templates import REVIEW_NAME, USAGE_LOG_NAME
from skill_log.version import version

# The ownership marker: it is the one thing that says this tool wrote the file.
comptime HOOK_MARKER = "# skill-log:post-merge-hook"

comptime HOOK_NAME = "post-merge"

# The hook's mode: git runs a hook only when it is executable, so the file
# carries its execute bits at creation.
comptime HOOK_MODE = 493  # 0755

comptime ARTIFACT_STORE = "store"
comptime ARTIFACT_HOOK = "hook"
comptime ARTIFACT_REPORT_DIR = "report_dir"
comptime ARTIFACT_SKILLS = "skills"

comptime STATUS_CREATED = "created"
comptime STATUS_UPDATED = "updated"
comptime STATUS_UNCHANGED = "unchanged"
comptime STATUS_DRIFT = "drift"
comptime STATUS_SKIPPED = "skipped"




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
    """Read `setup`'s flags."""
    var options = Options()
    var value_flags = setup_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--repo":
            options.repo = take_declared_value(
                args, i, "--repo", "a directory", value_flags
            )
            i += 1
        elif arg == "--skills-dir":
            options.skills_dir = take_declared_value(
                args, i, "--skills-dir", "a directory", value_flags
            )
            i += 1
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
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

    if options.check and options.remove_hook:
        raise Error(
            "usage: --check verifies and --remove-hook removes; pick one"
        )
    if options.remove_hook and options.no_hook:
        raise Error(
            "usage: --remove-hook and --no-hook cannot be combined"
        )

    return options^




def hook_script() -> String:
    """The post-merge hook `setup` writes."""
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
    """True when `text` carries the ownership marker at a line start."""
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




struct Verdict(Movable):
    """One artifact's verdict: its name, what happened, and why."""

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
    var out = JsonObject()
    out.put("artifact", verdict.artifact)
    out.put("status", verdict.status)
    out.put("detail", verdict.detail)
    return out.render()


def store_verdict(path: String, check: Bool, dry_run: Bool) raises -> Verdict:
    """The store's verdict: `create`, or `verify` under `--check`.

    The verdict comes from the store's own path, never from inspecting
    SQLite here. A refused store is drift with the refusal's own named
    message: setup creates a store and never migrates one.
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
    try:
        var opened = open_write(path)
        if opened.refusal.refused():
            return Verdict(
                ARTIFACT_STORE, STATUS_DRIFT, opened.refusal.failure().message
            )
    except e:
        return Verdict(
            ARTIFACT_STORE, STATUS_DRIFT, write_failure(path, String(e)).message
        )
    return Verdict(ARTIFACT_STORE, STATUS_CREATED, path)


def hook_verdict(common: String, options: Options) raises -> Verdict:
    """The post-merge hook's verdict in the common hooks directory."""
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
            return Verdict(
                ARTIFACT_HOOK,
                STATUS_DRIFT,
                "the post-merge hook at "
                + path
                + " carries no ownership marker",
            )
        if text == wanted:
            if not is_executable(path):
                if options.check:
                    return Verdict(
                        ARTIFACT_HOOK,
                        STATUS_DRIFT,
                        "the post-merge hook at "
                        + path
                        + " is not executable (git skips a hook it"
                        + " cannot run)",
                    )
                if options.dry_run:
                    return Verdict(
                        ARTIFACT_HOOK,
                        STATUS_UPDATED,
                        "would make " + path + " executable",
                    )
                set_executable(path)
                return Verdict(
                    ARTIFACT_HOOK, STATUS_UPDATED, "made " + path + " executable"
                )
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
    """`--remove-hook`: remove the marked hook, and only that."""
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
    """The report directory's verdict."""
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


def skills_verdict(skills_dir: String, options: Options) raises -> Verdict:
    """The installed skills' verdict."""
    if String(skills_dir.strip()) == "":
        return Verdict(
            ARTIFACT_SKILLS, STATUS_SKIPPED, "no --skills-dir given"
        )
    var dir = String(expand_home(String(skills_dir.strip())))
    if Path(dir).is_file():
        return Verdict(
            ARTIFACT_SKILLS, STATUS_SKIPPED, dir + " is not a directory"
        )

    var template_dir = resolve_template_dir("")
    var usage: Template
    var review: Template
    try:
        usage = load_template(USAGE_LOG_NAME, template_dir)
        review = load_template(REVIEW_NAME, template_dir)
        validate_effective(USAGE_LOG_NAME, usage)
        validate_effective(REVIEW_NAME, review)
    except e:
        return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, String(e))
    var command = resolved_command()

    var wanted_log = String("")
    var wanted_review = String("")
    try:
        wanted_log = skill_log_document(usage.content, command)
        wanted_review = review_document(review.content, usage.content, command)
    except e:
        return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, String(e))

    var entries = List[SkillInstall]()
    var created = False
    var updated = False
    var drift = False
    var skipped = False
    for i in range(2):
        var name: String
        var wanted: String
        if i == 0:
            name = SKILL_LOG_SKILL
            wanted = wanted_log
        else:
            name = REVIEW_SKILL
            wanted = wanted_review
        var entry = installed_skill_action(dir, name, wanted, options)
        var status = entry.status
        entries.append(entry^)
        if status == STATUS_CREATED:
            created = True
        elif status == STATUS_UPDATED:
            updated = True
        elif status == STATUS_DRIFT:
            drift = True
        elif status == STATUS_SKIPPED:
            skipped = True

    var detail = String("")
    for i in range(len(entries)):
        if i > 0:
            detail += ", "
        detail += entries[i].text()

    var moved = moved_default_note(usage, review)
    if moved != "":
        if detail != "":
            detail += "; "
        detail += moved
        if options.check:
            return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, detail)

    if drift:
        return Verdict(ARTIFACT_SKILLS, STATUS_DRIFT, detail)
    if created:
        return Verdict(ARTIFACT_SKILLS, STATUS_CREATED, detail)
    if updated:
        return Verdict(ARTIFACT_SKILLS, STATUS_UPDATED, detail)
    if skipped:
        return Verdict(ARTIFACT_SKILLS, STATUS_SKIPPED, detail)
    return Verdict(ARTIFACT_SKILLS, STATUS_UNCHANGED, detail)


struct SkillInstall(Movable):
    """One skill's install answer: its status and the reason for it."""

    var name: String
    var status: String
    var reason: String

    def __init__(
        out self, name: String = "", status: String = "", reason: String = ""
    ):
        self.name = name
        self.status = status
        self.reason = reason

    def text(self) -> String:
        """The human line: the skill, its status, and the reason."""
        return self.name + ":" + self.status + " (" + self.reason + ")"


def installed_skill_action(
    dir: String,
    name: String,
    wanted: String,
    options: Options,
) raises -> SkillInstall:
    """One skill's install answer, as `name:verdict` with its reason.

    Is it there at all? Is it this version's install? Does the stamp match?
    Under `--check` nothing is written. A vendored copy is skipped entirely.
    """
    var path = dir + "/" + name + "/SKILL.md"
    if not Path(path).is_file():
        if options.check:
            return SkillInstall(name, STATUS_DRIFT, "missing at " + path)
        if options.dry_run:
            return SkillInstall(
                name, STATUS_CREATED, "would write " + path
            )
        if not Path(dir + "/" + name).is_dir():
            makedirs(dir + "/" + name, exist_ok=True)
        write_text(path, wanted)
        return SkillInstall(name, STATUS_CREATED, path)

    var text = read_text(path)
    if text == wanted:
        return SkillInstall(name, STATUS_UNCHANGED, path)
    if is_vendored(text):
        return SkillInstall(
            name, STATUS_SKIPPED, "vendored; " + path + " is left alone"
        )

    var stamp = ""
    if name == SKILL_LOG_SKILL:
        stamp = stamp_version(text)
    if stamp == "" and name == SKILL_LOG_SKILL:
        if options.check:
            return SkillInstall(
                name, STATUS_DRIFT, "no version stamp at " + path
            )
        if options.force:
            if not options.dry_run:
                write_text(path, wanted)
            return SkillInstall(name, STATUS_UPDATED, path)
        return SkillInstall(
            name,
            STATUS_SKIPPED,
            "no version stamp; left alone at "
            + path
            + "; use --force to replace",
        )
    if stamp != "" and stamp != version():
        if options.check:
            return SkillInstall(
                name, STATUS_DRIFT, "installed by " + stamp + " at " + path
            )
        if options.force:
            if not options.dry_run:
                write_text(path, wanted)
            return SkillInstall(
                name,
                STATUS_UPDATED,
                "was installed by " + stamp + ", this is " + version(),
            )
        return SkillInstall(
            name,
            STATUS_SKIPPED,
            "installed by "
            + stamp
            + ", this is "
            + version()
            + "; left alone at "
            + path,
        )
    if options.check:
        return SkillInstall(
            name, STATUS_DRIFT, "differs from this version at " + path
        )
    if options.force:
        if not options.dry_run:
            write_text(path, wanted)
        return SkillInstall(name, STATUS_UPDATED, path)
    return SkillInstall(
        name,
        STATUS_SKIPPED,
        "differing copy left alone at " + path + "; use --force to replace",
    )




def setup_usage() -> String:
    return "skill-log setup [--repo <dir>] [--skills-dir <dir>] [--db <path>]\n" \
           "                [--check] [--dry-run] [--json] [--force]\n" \
           "                [--remove-hook] [--no-hook] [--no-report-dir]"


def setup_examples() -> List[String]:
    var examples = List[String]()
    examples.append("skill-log setup")
    examples.append("skill-log setup --repo ~/src/myrepo --check")
    examples.append("skill-log setup --dry-run --json")
    examples.append("skill-log setup --remove-hook")
    return examples^


def setup_value_flags() -> List[String]:
    var flags = List[String]()
    flags.append("--repo")
    flags.append("--skills-dir")
    flags.append("--db")
    return flags^


def setup_notes() -> String:
    return "One command makes a machine and a repo ready: the store, the git\n" \
           "post-merge hook that resolves what a pull landed, the report\n" \
           "directory (.skill-log/reports/ with its README and keep file),\n" \
           "and the two bundled skills under --skills-dir. It prints the\n" \
           "machine identity the log will use, so the spelling every marker\n" \
           "must match is visible. Re-running is a no-op.\n" \
           "\n" \
           "The hook goes only into the repository's common hooks directory\n" \
           "(git rev-parse --git-common-dir), so a linked worktree shares one\n" \
           "hook. A post-merge without the ownership marker is refused by\n" \
           "name and never overwritten; --remove-hook removes only a marked\n" \
           "hook. The hook resolves the CLI at run time and never changes a\n" \
           "pull's exit status.\n" \
           "\n" \
           "--skills-dir installs the two bundled skills: skill-log (the\n" \
           "read-and-report skill, copied verbatim with a version stamp that\n" \
           "is its only provenance) and skill-friction-review (rendered from\n" \
           "the skill-friction-review.md template with the resolved binary\n" \
           "path, followed by its own usage-log block). Both audit ok on the\n" \
           "next skills audit. A differing copy is left alone and named\n" \
           "unless --force replaces it; customising the review skill means\n" \
           "editing the template, not the installed file.\n" \
           "\n" \
           "--check verifies the store, the hook, the report directory and\n" \
           "the installed skills instead of writing, and exits 1 on drift —\n" \
           "a missing skill, a stale or stripped version stamp, or a\n" \
           "differing copy. --dry-run shows what a real run would change. A\n" \
           "store written by another schema is named and left alone: setup\n" \
           "creates a store and never migrates one.\n" \
           "\n" \
           "--no-hook and --no-report-dir turn one artifact off. A directory\n" \
           "that is not a git checkout is skipped with a named reason,\n" \
           "exit 0."




def resolve_repo(flag: String) -> String:
    """The checkout `setup` works on: `--repo`, else this checkout."""
    if String(flag.strip()) != "":
        return git_toplevel(expand_home(String(flag.strip())))
    return git_toplevel("")


def handle_setup(args: List[String]) raises -> Outcome:
    """The `setup` handler."""
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

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

    var verdicts = List[Verdict]()
    verdicts.append(store_verdict(path, options.check, options.dry_run))
    verdicts.append(hook_verdict(common, options))
    verdicts.append(report_dir_verdict(repo, options))
    verdicts.append(skills_verdict(options.skills_dir, options))

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

    for i in range(len(verdicts)):
        if verdicts[i].status == STATUS_DRIFT:
            var outcome = Outcome.fail(verdicts[i].detail, EXIT_FAILURE())
            outcome.text = text
            return outcome^

    return Outcome.ok(text)
