"""The `add` verb: one invocation, its problems, and its marker."""

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
    """The flags that consume the next argument."""
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
    """Read `add`'s flags."""
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

    The explicit flag wins, then the field's `SKILL_LOG_*` variable, then
    the enabled adapter's value, then the built-in detection. A blank at
    every level means the field is unknown, and unknown is written as an
    empty string.
    """
    if String(flag.strip()) != "":
        return String(flag.strip())
    if String(variable.strip()) != "":
        return String(variable.strip())
    if String(adapter_value.strip()) != "":
        return String(adapter_value.strip())
    return String(detected.strip())


def handle_add(args: List[String]) raises -> Outcome:
    """The `add` handler."""
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    # `--problem -` reads the text from stdin; on a terminal it refuses, because
    # a hook must never block.
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

    var detected_worktree = detect_worktree()
    var worktree = resolve_field(
        options.worktree,
        env_or_empty("SKILL_LOG_WORKTREE"),
        "",
        detected_worktree,
    )

    var adapter_names = enabled_adapters(options.adapters)
    var adapter = apply_adapters(adapter_names, worktree)

    var row = Invocation()
    row.skill = String(options.skill.strip())
    row.harness = resolve_field(
        options.harness, env_or_empty("SKILL_LOG_HARNESS"), adapter.harness, ""
    )
    row.session = resolve_field(
        options.session, env_or_empty("SKILL_LOG_SESSION"), adapter.session, ""
    )
    row.parent = resolve_field(
        options.parent, env_or_empty("SKILL_LOG_PARENT"), "", ""
    )
    row.model = resolve_field(
        options.model, env_or_empty("SKILL_LOG_MODEL"), adapter.model, ""
    )
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
    if String(options.machine.strip()) != "":
        row.machine = String(options.machine.strip())
    else:
        try:
            row.machine = hostname()
        except e:
            return Outcome.fail(String(e), EXIT_FAILURE())

    # The machine namespaces every marker (`machine#id`): a `#` or a control
    # character would make the row unnameable.
    if row.machine.find("#") != -1 or sanitize(row.machine) != row.machine:
        return Outcome.fail(
            "usage: --machine names a marker; it cannot contain '#'"
            " or a control character",
            EXIT_USAGE(),
        )

    var clean = List[String]()
    for i in range(len(problems)):
        clean.append(sanitize(problems[i]))

    if options.dry_run:
        row.ts = preview_timestamp()
        row.problems = clean^
        return Outcome.ok(render_row_json(row))

    var result: WriteResult
    try:
        result = write_invocation(path, row, clean)
    except e:
        return Outcome.fail(String(e), EXIT_FAILURE())

    if result.refusal.refused():
        var failure = result.refusal.failure()
        return Outcome.fail(failure.message, failure.code)

    row.id = result.id
    row.problems = clean^
    if options.json:
        return Outcome.ok(render_row_json(row))
    return Outcome.ok(row.marker())
