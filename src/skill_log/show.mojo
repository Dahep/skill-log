"""The `show` verb: read the log back."""

from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_declared_value
from skill_log.render import render_row_json
from skill_log.store import (
    DEFAULT_LIMIT,
    Filters,
    Invocation,
    StoreOpen,
    is_skill_log_store,
    open_read,
    read_failure,
    read_invocations,
)
from skill_log.settings import resolve_db
from skill_log.table import join_lines, pad, shorten_home
from skill_log.text import sanitize

comptime LAST_MIN = 1
comptime LAST_MAX = 500


def show_usage() -> String:
    return "skill-log show [--skill <name>] [--machine <name>]\n" \
           "                   [--harness <name>] [--repo <name>] [--run <id>]\n" \
           "                   [--unresolved] [--last <n>] [--json] [--db <path>]"


def show_examples() -> List[String]:
    var examples = List[String]()
    examples.append("skill-log show")
    examples.append("skill-log show --skill diagnosing-bugs --last 5")
    examples.append("skill-log show --unresolved --json")
    return examples^


def show_value_flags() -> List[String]:
    var flags = List[String]()
    flags.append("--skill")
    flags.append("--machine")
    flags.append("--harness")
    flags.append("--repo")
    flags.append("--run")
    flags.append("--last")
    flags.append("--db")
    return flags^


def show_notes() -> String:
    return "Rows come back newest first. The table indents each problem\n" \
           "under the invocation it belongs to, and shortens a worktree\n" \
           "under your home directory to ~/.\n" \
           "\n" \
           "--run names a run in whichever namespace it was recorded in:\n" \
           "its session, its T3 thread or its parent. Matching all three\n" \
           "is what finds the tree around a run, not one row of it.\n" \
           "\n" \
           "--last takes a number between 1 and 500, 20 by default;\n" \
           "--unresolved keeps only the rows no commit has stamped yet.\n" \
           "\n" \
           "A filter that matches nothing says which filter it was, so\n" \
           "an empty answer is never mistaken for an empty log.\n" \
           "\n" \
           "--json prints one flat object per line, with every column,\n" \
           "the marker and the problems. An empty log prints nothing at\n" \
           "all, so the stream stays valid JSON lines.\n" \
           "\n" \
           "A read never writes: it creates no store and changes none."


struct Options(Movable):
    """The flags `show` accepts."""

    var skill: String
    var machine: String
    var harness: String
    var repo: String
    var run: String
    var unresolved: Bool
    var last: Int
    var json: Bool
    var db: String
    var given_skill: Bool
    var given_machine: Bool
    var given_harness: Bool
    var given_repo: Bool
    var given_run: Bool

    def __init__(out self):
        self.skill = ""
        self.machine = ""
        self.harness = ""
        self.repo = ""
        self.run = ""
        self.unresolved = False
        self.last = DEFAULT_LIMIT
        self.json = False
        self.db = ""
        self.given_skill = False
        self.given_machine = False
        self.given_harness = False
        self.given_repo = False
        self.given_run = False


def parse_last(text: String) raises -> Int:
    if text == "":
        raise Error("usage: " + last_range_message())
    for c in text.codepoints():
        var code = Int(c)
        if code < 48 or code > 57:
            raise Error("usage: " + last_range_message())
    var value = 0
    for c in text.codepoints():
        value = value * 10 + (Int(c) - 48)
        if value > LAST_MAX:
            raise Error("usage: " + last_range_message())
    if value < LAST_MIN:
        raise Error("usage: " + last_range_message())
    return value


def last_range_message() -> String:
    return "--last takes a number between 1 and 500"


def parse_options(args: List[String]) raises -> Options:
    """Read `show`'s flags.

    An unknown flag, a missing value or an empty filter value is a usage
    error, raised as a `usage` marker the caller turns into exit 2.
    """
    var options = Options()
    var value_flags = show_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--skill":
            options.skill = take_declared_value(
                args, i, "--skill", "a name", value_flags
            )
            options.given_skill = True
            i += 1
        elif arg == "--machine":
            options.machine = take_declared_value(
                args, i, "--machine", "a name", value_flags
            )
            options.given_machine = True
            i += 1
        elif arg == "--harness":
            options.harness = take_declared_value(
                args, i, "--harness", "a name", value_flags
            )
            options.given_harness = True
            i += 1
        elif arg == "--repo":
            options.repo = take_declared_value(
                args, i, "--repo", "a name", value_flags
            )
            options.given_repo = True
            i += 1
        elif arg == "--run":
            options.run = take_declared_value(
                args, i, "--run", "an id", value_flags
            )
            options.given_run = True
            i += 1
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
            i += 1
        elif arg == "--last":
            options.last = parse_last(
                take_declared_value(args, i, "--last", "a number", value_flags)
            )
            i += 1
        elif arg == "--unresolved":
            options.unresolved = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    if options.given_skill and String(options.skill.strip()) == "":
        raise Error("usage: --skill needs a name")
    if options.given_machine and String(options.machine.strip()) == "":
        raise Error("usage: --machine needs a name")
    if options.given_harness and String(options.harness.strip()) == "":
        raise Error("usage: --harness needs a name")
    if options.given_repo and String(options.repo.strip()) == "":
        raise Error("usage: --repo needs a name")
    if options.given_run and String(options.run.strip()) == "":
        raise Error("usage: --run needs an id")

    return options^


def empty_message(filters: Filters) -> String:
    """What the table prints when nothing matched."""
    var parts = List[String]()
    if filters.skill != "":
        parts.append("--skill " + sanitize(filters.skill))
    if filters.machine != "":
        parts.append("--machine " + sanitize(filters.machine))
    if filters.harness != "":
        parts.append("--harness " + sanitize(filters.harness))
    if filters.repo != "":
        parts.append("--repo " + sanitize(filters.repo))
    if filters.run != "":
        parts.append("--run " + sanitize(filters.run))

    if len(parts) == 0:
        return "no invocations logged yet"

    var out = "no invocations match "
    for i in range(len(parts)):
        if i > 0:
            out += " and "
        out += parts[i]
    return out


def table_headers() -> List[String]:
    """The table's column names, in the order they are printed."""
    var headers = List[String]()
    headers.append("inv")
    headers.append("ts")
    headers.append("machine")
    headers.append("harness")
    headers.append("session")
    headers.append("parent")
    headers.append("model")
    headers.append("repo")
    headers.append("worktree")
    headers.append("project")
    headers.append("t3_thread")
    headers.append("skill")
    headers.append("fix")
    headers.append("resolved_at")
    return headers^


def cell(row: Invocation, column: String) -> String:
    """One table cell: the row's field, rendered for a person."""
    if column == "inv":
        return String(row.id)
    if column == "ts":
        return sanitize(row.ts)
    if column == "machine":
        return sanitize(row.machine)
    if column == "harness":
        return sanitize(row.harness)
    if column == "session":
        return sanitize(row.session)
    if column == "parent":
        return sanitize(row.parent)
    if column == "model":
        return sanitize(row.model)
    if column == "repo":
        return sanitize(row.repo)
    if column == "worktree":
        return shorten_home(sanitize(row.worktree))
    if column == "project":
        return sanitize(row.project)
    if column == "t3_thread":
        return sanitize(row.t3_thread)
    if column == "skill":
        return sanitize(row.skill)
    if column == "fix":
        return sanitize(row.fix)
    if column == "resolved_at":
        return sanitize(row.resolved_at)
    return ""


def table_widths(rows: List[Invocation]) -> List[Int]:
    """The width of every column: the widest cell in it, header included."""
    var headers = table_headers()
    var widths = List[Int]()
    for i in range(len(headers)):
        widths.append(headers[i].count_codepoints())
    for r in range(len(rows)):
        for c in range(len(headers)):
            var text = cell(rows[r], headers[c])
            if text.count_codepoints() > widths[c]:
                widths[c] = text.count_codepoints()
    return widths^


def render_table(rows: List[Invocation]) -> String:
    """The table for a person: a header row, one line per invocation, and each problem indented under its invocation."""
    var headers = table_headers()
    var widths = table_widths(rows)
    var lines = List[String]()

    var header = ""
    for c in range(len(headers)):
        if c > 0:
            header += "  "
        if c == len(headers) - 1:
            header += headers[c]
        else:
            header += pad(headers[c], widths[c])
    lines.append(header)

    for r in range(len(rows)):
        var line = ""
        for c in range(len(headers)):
            if c > 0:
                line += "  "
            if c == len(headers) - 1:
                line += cell(rows[r], headers[c])
            else:
                line += pad(cell(rows[r], headers[c]), widths[c])
        lines.append(String(line.rstrip()))
        for p in range(len(rows[r].problems)):
            lines.append(
                "    problem " + String(p + 1) + ": " + rows[r].problems[p]
            )

    return join_lines(lines)


def handle_show(args: List[String]) raises -> Outcome:
    """The `show` handler."""
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    var path = resolve_db(options.db)

    var filters = Filters()
    filters.skill = String(options.skill.strip())
    filters.machine = String(options.machine.strip())
    filters.harness = String(options.harness.strip())
    filters.repo = String(options.repo.strip())
    filters.run = String(options.run.strip())
    filters.unresolved = options.unresolved
    filters.limit = options.last

    var opened: StoreOpen
    try:
        opened = open_read(path)
    except e:
        var failure = read_failure(path, String(e))
        return Outcome.fail(failure.message, failure.code)

    if opened.refusal.refused():
        var failure = opened.refusal.failure()
        return Outcome.fail(failure.message, failure.code)

    var rows = List[Invocation]()
    if opened.db:
        var db = opened.db.take()
        try:
            if is_skill_log_store(db):
                rows = read_invocations(db, filters)
        except e:
            var failure = read_failure(path, String(e))
            return Outcome.fail(failure.message, failure.code)

    if len(rows) == 0:
        if options.json:
            return Outcome.ok("")
        return Outcome.ok(empty_message(filters))

    if options.json:
        var lines = List[String]()
        for i in range(len(rows)):
            lines.append(render_row_json(rows[i]))
        return Outcome.ok(join_lines(lines))

    return Outcome.ok(render_table(rows))
