"""The `skills` verb: `audit`, `adopt`, and `template show|seed|reset`.

The subcommands live under `skills`, split at the sub-verb (not as mode
flags):

- `skills audit` — read-only. Classify every skill's fenced usage-log
  block as `ok`, `missing`, `stale`, `edited` or `vendored`, one line
  per skill, exit 1 on anything but `ok`/`vendored`. Writes nothing —
  not even a state directory.
- `skills adopt` — write: append a block where there is none, rewrite a
  `stale` one, rewrite an `edited` one only with `--force`, skip
  `vendored` skills and leave `ok` ones alone. Every write goes through
  the `document` module's splice and `files.mojo`'s atomic replacement;
  no byte outside the fence is ever touched. Exit 0 when the directory
  ends conformant, 1 when any skill is refused.
- `skills template show|seed|reset` — the two shipped default templates
  and the user's copies of them. `show` reports the effective templates,
  their source, hashes and whether the shipped default moved since the
  copy was seeded. `seed` copies the shipped defaults into the user
  directory. `reset` deletes the user copies. Both refuse without
  `--force` and both support `--dry-run`.

## The templates

Two shipped defaults, embedded in the binary (`templates.mojo`),
resolved over the user's copies:

1. `--template-dir <dir>`
2. `SKILL_LOG_TEMPLATE_DIR`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/skill-log/templates/`
4. the shipped default in the binary

The effective template is the first source that has the file. Its hash
is the hash of its own bytes (the fence records that hash). The
seeded-from record — the hash of the shipped default each user copy was
seeded from — lives under XDG state, never under the user config dir, so
`show` and `audit` can report `moved` by comparing it to the current
shipped default. A moved default is *reported* with the two commands
that adopt it (`skills template seed --force`, then `skills adopt`) and
never applied.

## The vendored stamp

A skill whose frontmatter carries `metadata:` with a `source:` key is a
copy of someone else's skill and is skipped entirely (see
`document.is_vendored`). This is a ticket-level decision: the brief asks
for this machine's vendored-skill convention, the dotfiles repo's
vendored `tuicr` skill being the model.
"""

from std.os import getenv, listdir, makedirs, remove, rmdir
from std.pathlib import Path
from std.sys import argv

from skill_log.document import (
    STATE_EDITED,
    STATE_MISSING,
    STATE_OK,
    STATE_STALE,
    STATE_VENDORED,
    append,
    classify,
    frontmatter_name,
    is_vendored,
    render,
    rewrite,
    validate_template,
)
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.files import resolve_path, write_text
from skill_log.flags import take_value
from skill_log.hash import fnv1a64_hex
from skill_log.json import json_bool, json_string
from skill_log.templates import (
    REVIEW_NAME,
    USAGE_LOG_NAME,
    shipped_template,
    template_names,
)

# The state directory that records the seeded-from hash of each user
# copy. It is under XDG state — never under the user config dir — so a
# tool that reads the config dir never trips over it.
comptime STATE_DIR_NAME = "skill-log"

# The relative path of the seeded-from record inside the state dir. One
# file per template name, so each copy's provenance is its own.
comptime SEEDED_DIR = "seeded-from"

# The two files `seed` writes and `reset` deletes.
comptime USAGE_LOG_FILE = "usage-log.md"
comptime REVIEW_FILE = "skill-friction-review.md"

# The five actions `adopt` reports, exactly the SPEC §5.10 vocabulary.
comptime ACTION_APPENDED = "appended"
comptime ACTION_REWRITTEN = "rewritten"
comptime ACTION_UNCHANGED = "unchanged"
comptime ACTION_REFUSED = "refused"
comptime ACTION_SKIPPED = "skipped"

# The actions `template seed` and `template reset` report, exactly the
# SPEC §5.10 vocabulary. One action per template, so a caller reads a
# value and never matches prose:
#
#   seeded      — the shipped default was copied into the user directory
#   would_seed  — a dry run: the copy would be written, and nothing was
#   refused     — a copy is already there and `--force` was not given
#   deleted     — the user copy was removed
#   would_delete— a dry run: the copy would be removed, and nothing was
#   absent      — there was no user copy to remove
comptime TEMPLATE_ACTION_SEEDED = "seeded"
comptime TEMPLATE_ACTION_WOULD_SEED = "would_seed"
comptime TEMPLATE_ACTION_REFUSED = "refused"
comptime TEMPLATE_ACTION_DELETED = "deleted"
comptime TEMPLATE_ACTION_WOULD_DELETE = "would_delete"
comptime TEMPLATE_ACTION_ABSENT = "absent"


# --------------------------------------------------------------- paths


def xdg_state_dir() -> String:
    """The skill-log state directory, per the XDG rules.

    `XDG_STATE_HOME` first, else `$HOME/.local/state`. The store lives
    beside this in `skills.db`; the seeded-from record lives in
    `seeded-from.txt` here.
    """
    var xdg = getenv("XDG_STATE_HOME", "")
    if xdg != "":
        return xdg + "/" + STATE_DIR_NAME
    return getenv("HOME", "") + "/.local/state/" + STATE_DIR_NAME


def xdg_config_dir() -> String:
    """The user template directory, per the XDG rules.

    `XDG_CONFIG_HOME` first, else `$HOME/.config`. The templates are the
    `skill-log/templates/` directory inside it.
    """
    var xdg = getenv("XDG_CONFIG_HOME", "")
    if xdg == "":
        xdg = getenv("HOME", "") + "/.config"
    return xdg + "/" + STATE_DIR_NAME + "/templates"


def default_template_dir() -> String:
    """The user template directory (source 3 in the resolution chain)."""
    return xdg_config_dir()


def resolve_template_dir(flag: String) -> String:
    """The effective template directory, by the spec's chain.

    `--template-dir` first, then `SKILL_LOG_TEMPLATE_DIR`, then the user
    config directory. The shipped defaults are a separate fallback: a
    directory that does not contain a given template name falls through
    to the shipped default for that name.
    """
    if String(flag.strip()) != "":
        return String(flag.strip())
    var env = getenv("SKILL_LOG_TEMPLATE_DIR", "")
    if String(env.strip()) != "":
        return String(env.strip())
    return default_template_dir()


def find_in_path(program: String) -> String:
    """`program` as the first executable name on `PATH`, or unchanged.

    The shell's own first-match rule, for when the tool is invoked by
    bare name: `PATH` is walked left to right and the first entry that
    holds the file wins. A name `PATH` does not carry comes back as it
    went in — the caller still resolves it, and still falls back to the
    given name.
    """
    var path = getenv("PATH", "")
    var start = 0
    var n = path.byte_length()
    while start <= n:
        var cut = path.find(":", start)
        if cut < 0:
            cut = n
        var entry = String(path[byte=start:cut])
        if entry != "":
            var candidate = entry + "/" + program
            if Path(candidate).is_file():
                return candidate
        start = cut + 1
    return program


def resolved_command() -> String:
    """The path of this binary, resolved: `<command>`'s value.

    "The resolved binary path" is one answer no matter how the tool was
    invoked: a bare name is looked up on `PATH`, and whatever is found —
    or given — is resolved to one absolute, symlink-free path by
    `resolve_path`. A name the filesystem cannot resolve (a deleted
    binary, say) is used as it was given rather than dropped.
    """
    var all = argv()
    var program = String(all[0])
    if program.find("/") < 0:
        program = find_in_path(program)
    var real = resolve_path(program)
    if real != "":
        return real
    return program


# ------------------------------------------------------- the seeded-from


def seeded_path(name: String) -> String:
    """Where the seeded-from record for template `name` lives (XDG
    state)."""
    return xdg_state_dir() + "/" + SEEDED_DIR + "/" + name


def read_seeded(name: String) -> String:
    """The seeded-from hash of the user's `name` copy, or "".

    The record is a single line: the hash of the shipped default the
    copy was seeded from. A missing record means the copy predates the
    record (or was never seeded here) — reported as unknown, not moved.
    """
    var path = seeded_path(name)
    if not Path(path).is_file():
        return ""
    try:
        var text = Path(path).read_text()
        var line = String(text.strip())
        return line
    except:
        return ""


def write_seeded(name: String, hash_value: String) raises:
    """Record the seeded-from hash for template `name` under XDG state."""
    var dir = xdg_state_dir() + "/" + SEEDED_DIR
    makedirs(dir, exist_ok=True)
    write_text(seeded_path(name), hash_value + "\n")


def clear_seeded(name: String) raises:
    """Remove the seeded-from record for template `name` (as `reset`)."""
    var path = seeded_path(name)
    if Path(path).is_file():
        remove(path)


# ----------------------------------------------------- template loading


struct Template(Movable):
    """One effective template: its bytes, its source, its hash."""

    var name: String
    var content: String
    var source: String
    var hash: String
    var moved: Bool

    def __init__(out self):
        self.name = ""
        self.content = ""
        self.source = "shipped"
        self.hash = ""
        self.moved = False


def load_template(name: String, template_dir: String) raises -> Template:
    """The effective template `name`, resolved over the shipped default.

    The source is the first of the chain that has the file: the resolved
    directory, then the shipped default embedded in the binary. The hash
    is of the effective bytes. `moved` is set when the file came from the
    user directory and the shipped default's hash differs from the
    seeded-from hash on record — that is the "the shipped default moved
    since this copy was seeded" report.
    """
    var out = Template()
    out.name = name
    var candidate = template_dir + "/" + name
    if template_dir != "" and Path(candidate).is_file():
        try:
            out.content = Path(candidate).read_text()
            out.source = candidate
        except e:
            raise Error("cannot read template " + candidate + ": " + String(e))
    else:
        out.content = shipped_template(name)
        out.source = "shipped"
    out.hash = fnv1a64_hex(out.content)

    # A user copy's provenance: compare the shipped default's current
    # hash to the hash the copy was seeded from. Only a user copy has a
    # seeded-from record to compare against; a shipped default cannot
    # have "moved" from itself.
    if out.source != "shipped":
        var seeded = read_seeded(name)
        if seeded != "":
            var shipped_hash = fnv1a64_hex(shipped_template(name))
            out.moved = seeded != shipped_hash
    return out^


def validate_effective(name: String, template: Template) raises:
    """Refuse a template whose placeholders are wrong, by name.

    This is the boundary guard the brief asks for: a usage-log template
    that lost its `<name>` or its `<command> add` invocation would
    silently stop every skill from logging, so it is refused before it
    renders.
    """
    try:
        validate_template(name, template.content)
    except e:
        raise Error(String(e))


# ----------------------------------------------------------- dir listing


def skill_dirs(dir: String) raises -> List[String]:
    """The skill subdirectories of `dir`: those holding a `SKILL.md`.

    A skill is a subdirectory of `--dir` with a `SKILL.md` in it. The
    names come back sorted so the report is deterministic. A directory
    that does not exist is an empty list; the caller decides what an
    empty answer means (audit refuses one).
    """
    var out = List[String]()
    if not Path(dir).is_dir():
        return out^
    var entries = listdir(dir)
    var names = List[String]()
    for i in range(len(entries)):
        var name = String(entries[i])
        if name == "." or name == "..":
            continue
        var sub = dir + "/" + name
        if Path(sub).is_dir() and Path(sub + "/SKILL.md").is_file():
            names.append(name)
    # Sort: Mojo has no sort for a List of String in this toolchain's
    # surface, so the insertion sort is explicit and stable.
    for i in range(1, len(names)):
        var key = names[i]
        var j = i - 1
        while j >= 0 and names[j] > key:
            names[j + 1] = names[j]
            j -= 1
        names[j + 1] = key
    return names^


# ------------------------------------------------------------- auditing


struct SkillState(Movable):
    """One skill's audit result: its name, path, and state."""

    var skill: String
    var path: String
    var state: String

    def __init__(out self):
        self.skill = ""
        self.path = ""
        self.state = ""


def audit_skill(
    dir: String,
    name: String,
    current_template_hash: String,
    current_content_hash: String,
) raises -> SkillState:
    """One skill's state, from its `SKILL.md`."""
    var result = SkillState()
    result.skill = name
    result.path = dir + "/" + name
    var doc_path = result.path + "/SKILL.md"
    # The read either succeeds or raises, so `text` is always the file's
    # bytes below; the initial value only satisfies definite assignment.
    var text = String("")
    try:
        text = Path(doc_path).read_text()
    except e:
        raise Error("cannot read " + doc_path + ": " + String(e))
    # The document module owns the classification; the audit only names
    # the skill it came from. `is_vendored` short-circuits inside
    # `classify`, which is where the vendor stamp is decided.
    result.state = classify(
        text,
        current_template_hash,
        current_content_hash,
        is_vendored(text),
    )
    return result^


# ---------------------------------------------------------- adopting


struct Adopted(Movable):
    """One skill's adoption result: name, path, state, action."""

    var skill: String
    var path: String
    var state: String
    var action: String

    def __init__(out self):
        self.skill = ""
        self.path = ""
        self.state = ""
        self.action = ""


def adopt_skill(
    dir: String,
    name: String,
    template: Template,
    command: String,
    force: Bool,
    dry_run: Bool,
) raises -> Adopted:
    """Make one skill's document conform, and say what happened.

    The state is the document's state *before* the run (the same answer
    `audit` gives), and the action is what this run did with it:
    `missing` is appended to, `stale` rewritten, `edited` rewritten only
    with `--force` and otherwise refused, `ok` is left `unchanged`, and
    `vendored` is `skipped` entirely.

    The write is the `document` module's splice — `append` or `rewrite`
    — through `files.mojo`'s atomic replacement, so no byte outside the
    fence can change and no half-written file is ever visible. A dry
    run reports the same actions and writes nothing.
    """
    var result = Adopted()
    result.skill = name
    result.path = dir + "/" + name
    var doc_path = result.path + "/SKILL.md"
    var text = String("")
    try:
        text = Path(doc_path).read_text()
    except e:
        raise Error("cannot read " + doc_path + ": " + String(e))

    # The rendered block names the skill: `name:` from its frontmatter,
    # else the directory name it is called by everywhere else.
    var skill_name = frontmatter_name(text)
    if skill_name == "":
        skill_name = name
    var rendered = render(template.content, skill_name, command)
    result.state = classify(
        text,
        rendered.template_hash,
        rendered.content_hash,
        is_vendored(text),
    )

    if result.state == STATE_VENDORED:
        result.action = ACTION_SKIPPED
        return result^
    if result.state == STATE_OK:
        result.action = ACTION_UNCHANGED
        return result^
    if result.state == STATE_EDITED and not force:
        result.action = ACTION_REFUSED
        return result^

    var updated = String("")
    if result.state == STATE_MISSING:
        updated = append(text, rendered.text)
        result.action = ACTION_APPENDED
    else:
        updated = rewrite(text, rendered.text)
        result.action = ACTION_REWRITTEN
    if not dry_run:
        try:
            write_text(doc_path, updated)
        except e:
            raise Error("cannot write " + doc_path + ": " + String(e))
    return result^


def adopt_json_line(item: Adopted) -> String:
    """One adopt object, exactly `skill`, `path`, `state`, `action`
    (SPEC §5.10)."""
    return (
        "{\"skill\":"
        + json_string(item.skill)
        + ",\"path\":"
        + json_string(item.path)
        + ",\"state\":"
        + json_string(item.state)
        + ",\"action\":"
        + json_string(item.action)
        + "}"
    )


def adopt_text_line(item: Adopted) -> String:
    """One adopt line for a person: the action, the state, the skill."""
    return item.action + "  " + item.state + "  " + item.skill + "  " + item.path


# ------------------------------------------------------- JSON and text


def audit_json_line(item: SkillState) -> String:
    """One audit object, exactly `skill`, `path`, `state` (SPEC §5.10)."""
    return (
        "{\"skill\":"
        + json_string(item.skill)
        + ",\"path\":"
        + json_string(item.path)
        + ",\"state\":"
        + json_string(item.state)
        + "}"
    )


def audit_text_line(item: SkillState) -> String:
    """One audit line for a person: the state, the skill, the path."""
    return item.state + "  " + item.skill + "  " + item.path


def template_json(t: Template) -> String:
    """One template object, per SPEC §5.10's `skills template show`."""
    return (
        "{\"name\":"
        + json_string(t.name)
        + ",\"source\":"
        + json_string(t.source)
        + ",\"content\":"
        + json_string(t.content)
        + ",\"template_hash\":"
        + json_string(t.hash)
        + ",\"content_hash\":"
        + json_string(t.hash)
        + ",\"moved\":"
        + json_bool(t.moved)
        + "}"
    )


struct TemplateAction(Movable):
    """One template's outcome under `seed` or `reset`.

    The path is the file the action is about, and the action is one of
    the fixed tokens above. The human line is prose; the JSON carries
    the two values.
    """

    var path: String
    var action: String
    var note: String

    def __init__(
        out self, path: String = "", action: String = "", note: String = ""
    ):
        self.path = path
        self.action = action
        self.note = note


def template_action_json(item: TemplateAction) -> String:
    """One action object, exactly `path`, `action` (SPEC §5.10)."""
    return (
        "{\"path\":"
        + json_string(item.path)
        + ",\"action\":"
        + json_string(item.action)
        + "}"
    )


# ---------------------------------------------------------- subcommand


struct SkillsOptions(Movable):
    """The flags every `skills` subcommand accepts."""

    var sub: String
    var dir: String
    var template_dir: String
    var json: Bool
    var dry_run: Bool
    var force: Bool

    def __init__(out self):
        self.sub = ""
        self.dir = ""
        self.template_dir = ""
        self.json = False
        self.dry_run = False
        self.force = False


def parse_skills_options(args: List[String]) raises -> SkillsOptions:
    """Read `skills`'s subcommand and its flags.

    The first positional is the subcommand (`audit`, `template`, `adopt`);
    `template` takes a second positional (`show`, `seed`, `reset`). An
    unknown flag or a missing value is a usage error, raised as a
    `usage:` marker the caller turns into exit 2.
    """
    var options = SkillsOptions()
    var i = 0
    var positionals = List[String]()
    while i < len(args):
        var arg = args[i]
        if arg == "--dir":
            options.dir = take_value(args, i, "--dir", "a path")
            i += 1
        elif arg == "--template-dir":
            options.template_dir = take_value(
                args, i, "--template-dir", "a path"
            )
            i += 1
        elif arg == "--json":
            options.json = True
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--force":
            options.force = True
        elif arg.startswith("--"):
            raise Error("usage: unknown option: " + arg)
        else:
            positionals.append(arg)
        i += 1

    if len(positionals) == 0:
        raise Error("usage: skills needs a subcommand (audit, template, adopt)")
    options.sub = positionals[0]
    if options.sub == "template":
        if len(positionals) < 2:
            raise Error(
                "usage: skills template needs a subcommand (show, seed, reset)"
            )
        options.sub = "template " + positionals[1]
    elif len(positionals) > 1:
        raise Error("usage: skills " + options.sub + " takes no subcommand")
    return options^


# ------------------------------------------------------------- handlers


def skills_usage() -> String:
    """The usage line, as `--help` shows it."""
    return "skill-log skills <subcommand> [options]\n" \
           "\n" \
           "  skill-log skills audit --dir <dir> [--json] [--dry-run]\n" \
           "  skill-log skills adopt --dir <dir> [--force] [--dry-run] [--json]\n" \
           "  skill-log skills template show [--json] [--template-dir <dir>]\n" \
           "  skill-log skills template seed [--force] [--dry-run]\n" \
           "  skill-log skills template reset [--force] [--dry-run]"


def skills_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them."""
    var examples = List[String]()
    examples.append("skill-log skills audit --dir .agents/skills")
    examples.append("skill-log skills adopt --dir .agents/skills")
    examples.append("skill-log skills template show")
    examples.append("skill-log skills template seed --force")
    return examples^


def skills_value_flags() -> List[String]:
    """The flags that consume the next argument."""
    var flags = List[String]()
    flags.append("--dir")
    flags.append("--template-dir")
    return flags^


def skills_notes() -> String:
    """The paragraph between the usage line and the examples."""
    return "The subcommands, not mode flags: audit classifies, template\n" \
           "manages the two shipped defaults, adopt writes. audit is\n" \
           "read-only and exits 1 on any state but ok or vendored.\n" \
           "\n" \
           "adopt appends a block where there is none and rewrites a\n" \
           "stale one; an edited block is rewritten only with --force.\n" \
           "It never touches a byte outside the fence, and a second run\n" \
           "changes nothing. It exits 0 when the directory ends\n" \
           "conformant, 1 when any skill is refused.\n" \
           "\n" \
           "The templates resolve by --template-dir, then\n" \
           "SKILL_LOG_TEMPLATE_DIR, then\n" \
           "${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/, then the\n" \
           "shipped default in the binary. A moved shipped default is\n" \
           "reported with the two commands that adopt it (seed --force,\n" \
           "then adopt) and never applied.\n" \
           "\n" \
           "A vendored skill — one whose frontmatter carries metadata:\n" \
           "with a source: key — is skipped entirely: its wording belongs\n" \
           "to its upstream, not to this tool.\n" \
           "\n" \
           "See `skill-log skills template show --help` for the template\n" \
           "surface, `skill-log skills audit --help` for the states and\n" \
           "`skill-log skills adopt --help` for the write."


def render_verb_text() -> String:
    """The `skills` verb's own help block, for `skills --help`.

    It is the same block `render_verb` produces for the verb table: the
    summary, the usage line, the notes, and the real invocations. The
    subcommand help blocks (`subcommand_help`) are the nesting levels
    below it.
    """
    var text = (
        "skills — audit and adopt a skills directory, and manage the"
        " usage-log templates\n"
    )
    text += "\nusage:\n  " + skills_usage() + "\n"
    text += "\n" + skills_notes() + "\n"
    text += "\nexamples:\n"
    var examples = skills_examples()
    for i in range(len(examples)):
        text += "  " + examples[i] + "\n"
    return text


def subcommand_help(sub: String) -> String:
    """The usage block for one `skills` subcommand.

    Each nesting level's help ends with two to four real invocations, as
    the common rules require. The block is the subcommand's own: what it
    does, how to call it, and copy-pasteable examples.
    """
    if sub == "audit":
        return (
            "skills audit — classify every skill's usage-log block\n"
            "\nusage:\n"
            "  skill-log skills audit --dir <dir> [--json] [--dry-run]\n"
            "\n"
            "One line per skill, and exit 1 on any state but ok or\n"
            "vendored. Read-only: it writes nothing, not even a state\n"
            "directory. An empty directory is refused.\n"
            "\nexamples:\n"
            "  skill-log skills audit --dir .agents/skills\n"
            "  skill-log skills audit --dir .agents/skills --json\n"
            "  skill-log skills audit --dir .agents/skills --dry-run\n"
        )
    if sub == "adopt":
        return (
            "skills adopt — make a repo's skills conform\n"
            "\nusage:\n"
            "  skill-log skills adopt --dir <dir> [--force] [--dry-run]"
            " [--json]\n"
            "\n"
            "Appends a fenced block where there is none, rewrites a block\n"
            "whose content is an older render, and rewrites a hand-edited\n"
            "block only with --force. A vendored skill is skipped entirely.\n"
            "Not one byte outside the fence is rewritten or removed —\n"
            "unfenced text is never touched, not even with --force. A\n"
            "second run changes nothing.\n"
            "\n"
            "One line per skill: the action (appended, rewritten,\n"
            "unchanged, refused, skipped), the state it was in, the skill\n"
            "and its path. --json emits the same as one object per skill.\n"
            "--dry-run prints the same answer and writes nothing.\n"
            "\n"
            "Exits 0 when the directory ends conformant, 1 when any skill\n"
            "is refused — an edited block left untouched without --force.\n"
            "A directory that holds no skills is refused.\n"
            "\nexamples:\n"
            "  skill-log skills adopt --dir .agents/skills\n"
            "  skill-log skills adopt --dir .agents/skills --force\n"
            "  skill-log skills adopt --dir .agents/skills --dry-run --json\n"
        )
    if sub == "template show":
        return (
            "skills template show — the effective templates and their "
            "provenance\n"
            "\nusage:\n"
            "  skill-log skills template show [--json] [--template-dir <dir>]\n"
            "\n"
            "Prints both effective templates, their source, their hashes,\n"
            "and whether the shipped default has moved since the user copy\n"
            "was seeded. The usage-log template is also the pasteable\n"
            "snippet. A moved default is reported with the two commands\n"
            "that adopt it and never applied.\n"
            "\nexamples:\n"
            "  skill-log skills template show\n"
            "  skill-log skills template show --json\n"
            "  skill-log skills template show --template-dir ./my-templates\n"
        )
    if sub == "template seed":
        return (
            "skills template seed — copy the shipped defaults into the "
            "user directory\n"
            "\nusage:\n"
            "  skill-log skills template seed [--force] [--dry-run] [--json]\n"
            "\n"
            "Copies the two shipped defaults into\n"
            "${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/. Without\n"
            "--force it refuses to overwrite an existing copy.\n"
            "\n"
            "--json emits one object per template: the path and the\n"
            "action, which is one of seeded, would_seed (a dry run) or\n"
            "refused (a copy is already there).\n"
            "\nexamples:\n"
            "  skill-log skills template seed\n"
            "  skill-log skills template seed --force\n"
            "  skill-log skills template seed --force --dry-run\n"
        )
    if sub == "template reset":
        return (
            "skills template reset — delete the user copies, back to the "
            "shipped defaults\n"
            "\nusage:\n"
            "  skill-log skills template reset [--force] [--dry-run] [--json]\n"
            "\n"
            "Deletes the user copies and returns to the shipped defaults,\n"
            "which the next adopt re-renders. It refuses while copies\n"
            "exist unless --force is given.\n"
            "\n"
            "--json emits one object per template: the path and the\n"
            "action, which is one of deleted, would_delete (a dry run),\n"
            "absent (there was no copy) or refused (copies are there).\n"
            "\nexamples:\n"
            "  skill-log skills template reset --force\n"
            "  skill-log skills template reset --force --dry-run\n"
            "  skill-log skills template reset\n"
        )
    if sub == "template":
        return (
            "skills template — the two shipped usage-log templates\n"
            "\nusage:\n"
            "  skill-log skills template show [--json] [--template-dir <dir>]\n"
            "  skill-log skills template seed [--force] [--dry-run] [--json]\n"
            "  skill-log skills template reset [--force] [--dry-run] [--json]\n"
            "\n"
            "Subcommands, not mode flags: show reports, seed copies the\n"
            "shipped defaults into the user directory, reset deletes them\n"
            "back to the shipped defaults. The templates resolve by\n"
            "--template-dir, then SKILL_LOG_TEMPLATE_DIR, then\n"
            "${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/, then the\n"
            "shipped default in the binary.\n"
            "\n"
            "seed and reset emit one JSON object per template -- the path\n"
            "and the action -- so a caller reads a value and never\n"
            "matches prose.\n"
            "\nexamples:\n"
            "  skill-log skills template show\n"
            "  skill-log skills template seed --force\n"
            "  skill-log skills template reset --force\n"
        )
    return ""


def handle_skills(args: List[String]) raises -> Outcome:
    """The `skills` handler: dispatch on the subcommand.

    Returns the text to print on stdout, or the failure to report. It
    never prints and never exits: `main` owns both.

    A `--help` or `-h` anywhere in the call is a request for the
    subcommand's own help: `skills audit --help` prints the audit block,
    `skills template show --help` the show block, and `skills --help`
    the whole verb block. The subcommand is read from the first
    positional, so the help target is known before flags are parsed.
    """
    # Find the subcommand and whether help was asked for, without
    # parsing values: a bare scan, so `--dir --help` still treats
    # `--help` as a value of `--dir` only when it follows it. The verb's
    # value flags are the ones the dispatcher already knows, so the same
    # step-over rule applies here.
    var wants_help = False
    var positionals = List[String]()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--help" or arg == "-h":
            wants_help = True
        elif arg == "--dir" or arg == "--template-dir":
            i += 1
        elif not arg.startswith("--"):
            positionals.append(arg)
        i += 1

    if wants_help:
        if len(positionals) == 0:
            return Outcome.ok(render_verb_text())
        var sub = positionals[0]
        if sub == "template":
            if len(positionals) < 2:
                return Outcome.ok(subcommand_help("template"))
            sub = "template " + positionals[1]
        var block = subcommand_help(sub)
        if block == "":
            return Outcome.fail("unknown subcommand: " + sub, EXIT_USAGE())
        return Outcome.ok(block)

    var options: SkillsOptions
    try:
        options = parse_skills_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    if options.sub == "audit":
        return handle_audit(options)
    if options.sub == "adopt":
        return handle_adopt(options)
    if options.sub == "template show":
        return handle_template_show(options)
    if options.sub == "template seed":
        return handle_template_seed(options)
    if options.sub == "template reset":
        return handle_template_reset(options)
    return Outcome.fail(
        "unknown subcommand: " + options.sub, EXIT_USAGE()
    )


def handle_audit(options: SkillsOptions) raises -> Outcome:
    """`skills audit`: one line per skill, exit 1 on anything but
    ok/vendored, and writes nothing."""
    if String(options.dir.strip()) == "":
        return Outcome.fail("usage: skills audit needs --dir <dir>", EXIT_USAGE())
    var dir = String(options.dir.strip())

    # The current render is what the fence is compared against. The
    # effective template is validated first: a broken template must not
    # silently mark every skill stale.
    var template_dir = resolve_template_dir(options.template_dir)
    var template: Template
    try:
        template = load_template(USAGE_LOG_NAME, template_dir)
        validate_effective(USAGE_LOG_NAME, template)
    except e:
        return Outcome.fail(String(e), EXIT_FAILURE())

    var rendered = render(template.content, "skill", "skill-log")
    var names = skill_dirs(dir)
    if len(names) == 0:
        return Outcome.fail(
            "no skills in " + dir + " (no subdirectory holds a SKILL.md)",
            EXIT_FAILURE(),
        )

    var lines = List[String]()
    var dirty = False
    for i in range(len(names)):
        var item = audit_skill(
            dir,
            names[i],
            rendered.template_hash,
            rendered.content_hash,
        )
        if item.state != STATE_OK and item.state != STATE_VENDORED:
            dirty = True
        if options.json:
            lines.append(audit_json_line(item))
        else:
            lines.append(audit_text_line(item))

    var text = String("")
    for i in range(len(lines)):
        if i > 0:
            text += "\n"
        text += lines[i]

    if dirty:
        # The findings are the answer and go to stdout even when the
        # exit code says "not clean"; the summary is the one stderr line
        # the failure is allowed.
        var outcome = Outcome.fail("some skills need adoption", EXIT_FAILURE())
        outcome.text = text
        return outcome^
    return Outcome.ok(text)


def handle_adopt(options: SkillsOptions) raises -> Outcome:
    """`skills adopt`: make every skill in `--dir` conform.

    One line (or object) per skill, exit 0 when the directory ends
    conformant, exit 1 when any skill is refused — an `edited` block
    left untouched because `--force` was not given. `--dry-run` prints
    the same answer and writes nothing.
    """
    if String(options.dir.strip()) == "":
        return Outcome.fail("usage: skills adopt needs --dir <dir>", EXIT_USAGE())
    var dir = String(options.dir.strip())

    # The effective template is validated first: rendering from a broken
    # template would write blocks no skill can log from.
    var template_dir = resolve_template_dir(options.template_dir)
    var template: Template
    try:
        template = load_template(USAGE_LOG_NAME, template_dir)
        validate_effective(USAGE_LOG_NAME, template)
    except e:
        return Outcome.fail(String(e), EXIT_FAILURE())

    var command = resolved_command()
    var names = skill_dirs(dir)
    if len(names) == 0:
        return Outcome.fail(
            "no skills in " + dir + " (no subdirectory holds a SKILL.md)",
            EXIT_FAILURE(),
        )

    var lines = List[String]()
    var refused = False
    for i in range(len(names)):
        var item = Adopted()
        try:
            item = adopt_skill(
                dir,
                names[i],
                template,
                command,
                options.force,
                options.dry_run,
            )
        except e:
            return Outcome.fail(String(e), EXIT_FAILURE())
        if item.action == ACTION_REFUSED:
            refused = True
        if options.json:
            lines.append(adopt_json_line(item))
        else:
            lines.append(adopt_text_line(item))

    var text = String("")
    for i in range(len(lines)):
        if i > 0:
            text += "\n"
        text += lines[i]

    if refused:
        # The report is the answer and goes to stdout even when the exit
        # code says "not conformant"; the summary is the one stderr line
        # the failure is allowed.
        var outcome = Outcome.fail(
            "some skills were refused (an edited block is rewritten"
            " only with --force)",
            EXIT_FAILURE(),
        )
        outcome.text = text
        return outcome^
    return Outcome.ok(text)


def handle_template_show(options: SkillsOptions) raises -> Outcome:
    """`skills template show`: both effective templates, their source,
    hashes, and whether the shipped default has moved."""
    var template_dir = resolve_template_dir(options.template_dir)
    var usage: Template
    var review: Template
    try:
        usage = load_template(USAGE_LOG_NAME, template_dir)
        review = load_template(REVIEW_NAME, template_dir)
        validate_effective(USAGE_LOG_NAME, usage)
        validate_effective(REVIEW_NAME, review)
    except e:
        return Outcome.fail(String(e), EXIT_FAILURE())

    if options.json:
        var out = "{\"templates\":[" + template_json(usage) + ","
        out += template_json(review) + "]}"
        return Outcome.ok(out)

    var text = String("")
    text += "usage-log.md\n"
    text += "  source: " + usage.source + "\n"
    text += "  template_hash: " + usage.hash + "\n"
    text += "  content_hash: " + usage.hash + "\n"
    text += "  moved: " + (String("true") if usage.moved else String("false")) + "\n"
    text += "\nskill-friction-review.md\n"
    text += "  source: " + review.source + "\n"
    text += "  template_hash: " + review.hash + "\n"
    text += "  content_hash: " + review.hash + "\n"
    text += "  moved: " + (String("true") if review.moved else String("false")) + "\n"
    if usage.moved or review.moved:
        text += (
            "\nthe shipped default moved; adopt it with:\n"
            "  skill-log skills template seed --force\n"
            "  skill-log skills adopt --dir <dir>\n"
        )
    text += "\nusage-log snippet (paste into a skill):\n"
    text += usage.content + "\n"
    return Outcome.ok(text)


def handle_template_seed(options: SkillsOptions) raises -> Outcome:
    """`skills template seed`: copy the shipped defaults into the user
    directory, refusing an existing copy without `--force`.

    One action per template. The action is a fixed token, so the JSON
    carries the same fact the human line does; `--dry-run` previews the
    same shape and writes nothing.
    """
    var dir = default_template_dir()
    var names = template_names()
    var actions = List[TemplateAction]()
    var refused = False

    for i in range(len(names)):
        var name = names[i]
        var target = dir + "/" + name
        var exists = Path(target).is_file()
        if exists and not options.force:
            refused = True
            var note = name + ": refused (exists; use --force)"
            actions.append(
                TemplateAction(target^, TEMPLATE_ACTION_REFUSED, note)
            )
            continue
        var content = shipped_template(name)
        if options.dry_run:
            var note = name + ": would write " + target
            actions.append(
                TemplateAction(target^, TEMPLATE_ACTION_WOULD_SEED, note)
            )
            continue
        makedirs(dir, exist_ok=True)
        write_text(target, content)
        write_seeded(name, fnv1a64_hex(content))
        var note = name + ": wrote " + target
        actions.append(
            TemplateAction(target^, TEMPLATE_ACTION_SEEDED, note)
        )

    var text = String("")
    for i in range(len(actions)):
        if i > 0:
            text += "\n"
        if options.json:
            text += template_action_json(actions[i])
        else:
            text += actions[i].note

    if refused:
        var outcome = Outcome.fail(
            "seed refused an existing copy", EXIT_FAILURE()
        )
        outcome.text = text
        return outcome^
    return Outcome.ok(text)


def handle_template_reset(options: SkillsOptions) raises -> Outcome:
    """`skills template reset`: delete the user copies back to the
    shipped defaults, refusing while copies exist without `--force`.

    One action per template, with the same fixed tokens `seed` uses: a
    copy that is not there is `absent`, not a deletion.
    """
    var dir = default_template_dir()
    var names = template_names()
    var actions = List[TemplateAction]()
    var refused = False

    for i in range(len(names)):
        var name = names[i]
        var target = dir + "/" + name
        if not Path(target).is_file():
            var note = name + ": absent"
            actions.append(
                TemplateAction(target^, TEMPLATE_ACTION_ABSENT, note)
            )
            continue
        if not options.force:
            refused = True
            var note = name + ": refused (exists; use --force)"
            actions.append(
                TemplateAction(target^, TEMPLATE_ACTION_REFUSED, note)
            )
            continue
        if options.dry_run:
            var note = name + ": would delete " + target
            actions.append(
                TemplateAction(target^, TEMPLATE_ACTION_WOULD_DELETE, note)
            )
            continue
        remove(target)
        var note = name + ": deleted " + target
        actions.append(
            TemplateAction(target^, TEMPLATE_ACTION_DELETED, note)
        )

    if options.force and not options.dry_run:
        for i in range(len(names)):
            clear_seeded(names[i])

    var text = String("")
    for i in range(len(actions)):
        if i > 0:
            text += "\n"
        if options.json:
            text += template_action_json(actions[i])
        else:
            text += actions[i].note

    if refused:
        var outcome = Outcome.fail(
            "reset refused while copies exist", EXIT_FAILURE()
        )
        outcome.text = text
        return outcome^
    return Outcome.ok(text)
