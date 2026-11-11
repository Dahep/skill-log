"""The `add` verb: one invocation, its problems, and its marker.

`skill-log add --skill <name> [--problem <text>]...` records one skill
run and the friction it produced. A clean run still writes a row: the
invocation count is the denominator of the problems-per-invocation rate.

The write is one transaction — the invocation row, then one problem row
per `--problem`, then the commit — so a failed write leaves nothing
behind.

`add` is deliberately not idempotent. The log records occurrences: a
retry after a crashed run is indistinguishable from a genuine repeat,
and deduping would hide the second occurrence of one error. Two identical
calls therefore produce two rows, and the help says so.

## The context the row carries

ADR-0002 gives the row explicit harness context, and every field of it
is resolved by the same chain, one field at a time:

1. the explicit flag (`--repo`, `--model`, …)
2. that field's `SKILL_LOG_*` variable
3. an enabled adapter's value
4. the built-in detection

The chain is applied per field, not per row: `--repo` beats
`SKILL_LOG_REPO` beats the git detection, while `--model` still lets
the opencode adapter fill the session. A field nobody filled is
empty, and empty means "unknown".

The output is the row's marker, `machine#id`, on stdout. `--json` emits
the whole row flat, and `--dry-run` prints the row it would write and
writes nothing.
"""

from skill_log.adapters import apply_adapters, enabled_adapters
from skill_log.context import hostname, preview_timestamp, read_stdin_line, stdin_is_tty
from skill_log.detect import detect_repo, detect_worktree, env_or_empty
from skill_log.errors import EXIT_USAGE, Outcome
from skill_log.json import json_string, json_string_array
from skill_log.store import (
    Invocation,
    classify,
    resolve_db,
    sanitize,
    write_invocation,
)


struct Options(Movable):
    """The flags `add` accepts."""

    var skill: String
    var problems: List[String]
    var dry_run: Bool
    var json: Bool
    var db: String
    var harness: String
    var session: String
    var parent: String
    var model: String
    var repo: String
    var worktree: String
    var project: String
    var t3_thread: String
    var machine: String
    var adapters: List[String]

    def __init__(out self):
        self.skill = ""
        self.problems = List[String]()
        self.dry_run = False
        self.json = False
        self.db = ""
        self.harness = ""
        self.session = ""
        self.parent = ""
        self.model = ""
        self.repo = ""
        self.worktree = ""
        self.project = ""
        self.t3_thread = ""
        self.machine = ""
        self.adapters = List[String]()


def parse_options(args: List[String]) raises -> Options:
    """Read `add`'s flags.

    `--problem` is repeatable, `--db` takes a path, and `--adapter` is
    repeatable and also accepts a comma-separated list. An unknown flag
    or a missing value is a usage error, raised as a `usage` marker the
    caller turns into exit 2: one line, no write.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--skill":
            i += 1
            if i >= len(args):
                raise Error("usage: --skill needs a name")
            options.skill = String(args[i])
        elif arg == "--problem":
            i += 1
            if i >= len(args):
                raise Error("usage: --problem needs a text")
            options.problems.append(String(args[i]))
        elif arg == "--db":
            i += 1
            if i >= len(args):
                raise Error("usage: --db needs a path")
            options.db = String(args[i])
        elif arg == "--harness":
            i += 1
            if i >= len(args):
                raise Error("usage: --harness needs a name")
            options.harness = String(args[i])
        elif arg == "--session":
            i += 1
            if i >= len(args):
                raise Error("usage: --session needs an id")
            options.session = String(args[i])
        elif arg == "--parent":
            i += 1
            if i >= len(args):
                raise Error("usage: --parent needs an id")
            options.parent = String(args[i])
        elif arg == "--model":
            i += 1
            if i >= len(args):
                raise Error("usage: --model needs provider/id")
            options.model = String(args[i])
        elif arg == "--repo":
            i += 1
            if i >= len(args):
                raise Error("usage: --repo needs a name")
            options.repo = String(args[i])
        elif arg == "--worktree":
            i += 1
            if i >= len(args):
                raise Error("usage: --worktree needs a path")
            options.worktree = String(args[i])
        elif arg == "--project":
            i += 1
            if i >= len(args):
                raise Error("usage: --project needs a name")
            options.project = String(args[i])
        elif arg == "--t3-thread":
            i += 1
            if i >= len(args):
                raise Error("usage: --t3-thread needs an id")
            options.t3_thread = String(args[i])
        elif arg == "--machine":
            i += 1
            if i >= len(args):
                raise Error("usage: --machine needs a name")
            options.machine = String(args[i])
        elif arg == "--adapter":
            i += 1
            if i >= len(args):
                raise Error("usage: --adapter needs a name")
            options.adapters.append(String(args[i]))
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    if options.skill.strip() == "":
        raise Error("usage: --skill needs a name")

    # A blank problem carries no friction; it is ignored rather than
    # written as an empty row.
    var kept = List[String]()
    for i in range(len(options.problems)):
        if String(options.problems[i].strip()) != "":
            kept.append(options.problems[i])
    options.problems = kept^

    return options^


def resolve_field(
    flag: String, variable: String, adapter_value: String, detected: String
) -> String:
    """One field of the row, by ADR-0002's precedence.

    The explicit flag wins, then the field's `SKILL_LOG_*` variable,
    then the enabled adapter's value, then the built-in detection. A
    blank at every level means the field is unknown, and unknown is
    written as an empty string.
    """
    if String(flag.strip()) != "":
        return String(flag.strip())
    if String(variable.strip()) != "":
        return String(variable.strip())
    if String(adapter_value.strip()) != "":
        return String(adapter_value.strip())
    return String(detected.strip())


def render_json(row: Invocation) -> String:
    """The whole row as one flat JSON object.

    The key order is fixed, so a caller can read the output without
    parsing it into a guess about order.
    """
    var out = "{"
    if row.id > 0:
        out += "\"id\":" + String(row.id)
    else:
        out += "\"id\":null"
    out += ",\"ts\":" + json_string(row.ts)
    out += ",\"skill\":" + json_string(row.skill)
    out += ",\"harness\":" + json_string(row.harness)
    out += ",\"session\":" + json_string(row.session)
    out += ",\"parent\":" + json_string(row.parent)
    out += ",\"model\":" + json_string(row.model)
    out += ",\"repo\":" + json_string(row.repo)
    out += ",\"worktree\":" + json_string(row.worktree)
    out += ",\"project\":" + json_string(row.project)
    out += ",\"t3_thread\":" + json_string(row.t3_thread)
    out += ",\"machine\":" + json_string(row.machine)
    out += ",\"fix\":" + json_string(row.fix)
    out += ",\"resolved_at\":" + json_string(row.resolved_at)
    out += ",\"marker\":" + json_string(row.marker())
    out += ",\"problems\":" + json_string_array(row.problems)
    out += "}"
    return out


def handle_add(args: List[String]) raises -> Outcome:
    """The `add` handler.

    Returns the text to print on stdout, or the failure to report. It
    never prints and never exits: `main` owns both.
    """
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    # `--problem -` reads the text from stdin. On a terminal there is
    # nothing to read and the command would hang, so it refuses
    # instead: a hook must never block.
    var problems = List[String]()
    for i in range(len(options.problems)):
        var text = String(options.problems[i])
        if text == "-":
            if stdin_is_tty():
                return Outcome.fail(
                    "usage: --problem - reads from stdin, and stdin is a terminal",
                    EXIT_USAGE(),
                )
            text = read_stdin_line()
        if String(text.strip()) != "":
            problems.append(text)

    var path = resolve_db(options.db)

    # The worktree comes first: the t3 adapter needs it to find the
    # project, and the adapter's value sits below the flag and the
    # variable.
    var worktree = resolve_field(
        options.worktree,
        env_or_empty("SKILL_LOG_WORKTREE"),
        "",
        detect_worktree(),
    )

    var adapter_names = enabled_adapters(options.adapters)
    var adapter = apply_adapters(adapter_names, worktree)

    # Every field, by the same chain: the flag, then the variable,
    # then the adapter, then the detection.
    var row = Invocation()
    row.skill = String(options.skill.strip())
    row.harness = resolve_field(
        options.harness, env_or_empty("SKILL_LOG_HARNESS"), adapter.harness, ""
    )
    row.session = resolve_field(
        options.session, env_or_empty("SKILL_LOG_SESSION"), adapter.session, ""
    )
    # An adapter may not set the parent: it names a run this tool did
    # not spawn, and no adapter can know it.
    row.parent = resolve_field(
        options.parent, env_or_empty("SKILL_LOG_PARENT"), "", ""
    )
    row.model = resolve_field(
        options.model, env_or_empty("SKILL_LOG_MODEL"), adapter.model, ""
    )
    row.repo = resolve_field(
        options.repo, env_or_empty("SKILL_LOG_REPO"), "", detect_repo()
    )
    row.worktree = worktree
    row.project = resolve_field(
        options.project, env_or_empty("SKILL_LOG_PROJECT"), adapter.project, ""
    )
    row.t3_thread = resolve_field(
        options.t3_thread, env_or_empty("SKILL_LOG_T3_THREAD"), "", ""
    )
    # The machine is always detected: ADR-0002's environment list has
    # no `SKILL_LOG_MACHINE`, so the flag and the hostname are the only
    # two sources.
    row.machine = resolve_field(options.machine, "", "", hostname())

    # The problems are sanitized on the way in as well as on the way
    # out: a control character in a problem must never reach the store
    # and come back as two lines.
    var clean = List[String]()
    for i in range(len(problems)):
        clean.append(sanitize(problems[i]))

    if options.dry_run:
        # The row it would write, and nothing on disk. The timestamp is
        # read through an in-memory database, so a preview never creates
        # the store.
        row.ts = preview_timestamp()
        row.problems = clean^
        return Outcome.ok(render_json(row))

    try:
        var written = write_invocation(path, row, clean)
        row.id = written
        row.problems = clean^
        if options.json:
            return Outcome.ok(render_json(row))
        return Outcome.ok(row.marker())
    except e:
        var failure = classify(path, String(e))
        return Outcome.fail(failure.message, failure.code)
