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
from skill_log.context import hostname, preview_timestamp
from skill_log.detect import detect_repo, detect_worktree, env_or_empty
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_declared_value
from skill_log.render import render_row_json
from skill_log.settings import resolve_db
from skill_log.stdin import read_stdin_line, stdin_is_tty
from skill_log.store import Invocation, WriteResult, write_invocation
from skill_log.text import sanitize


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


def add_value_flags() -> List[String]:
    """The flags that consume the next argument.

    The declaration lives here, beside the parser that reads them, and
    the parser checks every flag it reads a value for against it. The
    dispatcher reads the same list to tell `--problem -h` (a problem
    spelled `-h`) from a help request.
    """
    var flags = List[String]()
    flags.append("--skill")
    flags.append("--problem")
    flags.append("--db")
    flags.append("--harness")
    flags.append("--session")
    flags.append("--parent")
    flags.append("--model")
    flags.append("--repo")
    flags.append("--worktree")
    flags.append("--project")
    flags.append("--t3-thread")
    flags.append("--machine")
    flags.append("--adapter")
    return flags^


def parse_options(args: List[String]) raises -> Options:
    """Read `add`'s flags.

    `--problem` is repeatable, `--db` takes a path, and `--adapter` is
    repeatable and also accepts a comma-separated list. An unknown flag
    or a missing value is a usage error, raised as a `usage` marker the
    caller turns into exit 2: one line, no write.

    A value is taken as written, whatever it looks like: `--problem -h`
    is the problem text `-h`, and the dispatcher's help scan knows that
    `--problem` consumes the next argument (`Verb.value_flags`).
    """
    var options = Options()
    var value_flags = add_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--skill":
            options.skill = take_declared_value(
                args, i, "--skill", "a name", value_flags
            )
            i += 1
        elif arg == "--problem":
            options.problems.append(
                take_declared_value(args, i, "--problem", "a text", value_flags)
            )
            i += 1
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
            i += 1
        elif arg == "--harness":
            options.harness = take_declared_value(
                args, i, "--harness", "a name", value_flags
            )
            i += 1
        elif arg == "--session":
            options.session = take_declared_value(
                args, i, "--session", "an id", value_flags
            )
            i += 1
        elif arg == "--parent":
            options.parent = take_declared_value(
                args, i, "--parent", "an id", value_flags
            )
            i += 1
        elif arg == "--model":
            options.model = take_declared_value(
                args, i, "--model", "provider/id", value_flags
            )
            i += 1
        elif arg == "--repo":
            options.repo = take_declared_value(
                args, i, "--repo", "a name", value_flags
            )
            i += 1
        elif arg == "--worktree":
            options.worktree = take_declared_value(
                args, i, "--worktree", "a path", value_flags
            )
            i += 1
        elif arg == "--project":
            options.project = take_declared_value(
                args, i, "--project", "a name", value_flags
            )
            i += 1
        elif arg == "--t3-thread":
            options.t3_thread = take_declared_value(
                args, i, "--t3-thread", "an id", value_flags
            )
            i += 1
        elif arg == "--machine":
            options.machine = take_declared_value(
                args, i, "--machine", "a name", value_flags
            )
            i += 1
        elif arg == "--adapter":
            options.adapters.append(
                take_declared_value(args, i, "--adapter", "a name", value_flags)
            )
            i += 1
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
    var detected_worktree = detect_worktree()
    var worktree = resolve_field(
        options.worktree,
        env_or_empty("SKILL_LOG_WORKTREE"),
        "",
        detected_worktree,
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
    # The repository is detected from the worktree the row carries, so
    # the two fields always describe the same checkout.
    row.repo = resolve_field(
        options.repo,
        env_or_empty("SKILL_LOG_REPO"),
        "",
        detect_repo(worktree),
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
    # two sources. A hostname that cannot be read is an error rather
    # than a blank: the machine namespaces the marker, so a row without
    # one is a row nothing can resolve.
    if String(options.machine.strip()) != "":
        row.machine = String(options.machine.strip())
    else:
        try:
            row.machine = hostname()
        except e:
            return Outcome.fail(String(e), EXIT_FAILURE())

    # The machine namespaces every marker (`machine#id`). A `#` or a
    # control character would make the row unnameable — and a newline
    # would split a report line — so an explicit value that carries one
    # is refused at the boundary.
    if row.machine.find("#") != -1 or sanitize(row.machine) != row.machine:
        return Outcome.fail(
            "usage: --machine names a marker; it cannot contain '#'"
            " or a control character",
            EXIT_USAGE(),
        )

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
        return Outcome.ok(render_row_json(row))

    var result: WriteResult
    try:
        result = write_invocation(path, row, clean)
    except e:
        # A refused store never reaches here: the refusal is a value, and
        # only a genuine failure to write raises — with the store's own
        # named message, already classified (SPEC §3). This handler
        # adds nothing to it.
        return Outcome.fail(String(e), EXIT_FAILURE())

    if result.refusal.refused():
        var failure = result.refusal.failure()
        return Outcome.fail(failure.message, failure.code)

    row.id = result.id
    row.problems = clean^
    if options.json:
        return Outcome.ok(render_row_json(row))
    return Outcome.ok(row.marker())
