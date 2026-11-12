"""The `show` verb: read the log back.

`skill-log show` prints the recorded invocations, newest first, with
their problems. It is the read half of the tool: it never writes, and a
read of a machine leaves that machine exactly as it found it.

## What it selects

The filters are the columns a reader slices by, plus two that name a
run rather than a field:

- `--skill`, `--machine`, `--harness`, `--repo` — exact matches.
- `--run <id>` — matches a row's `session`, its `t3_thread` or its
  `parent` (ADR-0002 §6). A run is named three ways, and the filter
  accepts all of them.
- `--unresolved` — the rows no commit has stamped yet.
- `--last N` — how many rows, newest first. The default is 20 and the
  range is 1..500.

The order is `datetime(ts) DESC, id DESC`: `datetime()` normalizes each
row's stamp (rows carry their writer's own UTC offset), so rows sort by
when the run happened rather than by when it was written. The id breaks a
tie, so the order is total and stable.

## What it prints

Two shapes, one flag apart:

- The table, for a person. A header row, one line per invocation, and
  each problem indented under the invocation it belongs to. Every field
  is sanitized the way the store sanitizes it, and the worktree is
  shortened under the home directory to `~/...`.
- `--json`, one flat object per row, for a pipe. Every column is flat,
  plus the marker and the problems array. An empty result prints
  nothing at all, so the stream stays parseable.

An absent or empty store is not an error: the table prints
`no invocations logged yet` and the JSON stream prints nothing. Both
exit 0. A filter that matches nothing says which filter it was, so an
empty answer is never mistaken for an empty log.

The reference's empty message knew two filters and phrased them
differently (`no invocations from machine X`). This one knows five and
phrases them the same way — `no invocations match --skill X and
--machine Y` — because a reader who gave three filters needs all three
named, and one rule reads the same however many filters there are.

A usage error is one named line and exit 2: the line says what is wrong
with the call and what to write instead.

A damaged, foreign, older or newer store is named once on stderr and
exits 1. A read never creates the store, the state directory or an empty
database.
"""

from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_value
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
    resolve_db,
)
from skill_log.table import join_lines, pad, shorten_home
from skill_log.text import sanitize

# The ends of the `--last` range. The upper bound keeps one call from
# pulling the whole log into memory; the lower bound is one, because
# zero rows is not a question anyone asks of a log.
comptime LAST_MIN = 1
comptime LAST_MAX = 500


def show_usage() -> String:
    """The usage line, as `--help` shows it.

    The verb's own text lives here, with its handler, so the usage a
    usage error prints and the usage `--help` prints are the same
    text — one source, two readers.
    """
    return "skill-log show [--skill <name>] [--machine <name>]\n" \
           "                   [--harness <name>] [--repo <name>] [--run <id>]\n" \
           "                   [--unresolved] [--last <n>] [--json] [--db <path>]"


def show_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them.

    Two to four, every one of them a call that works.
    """
    var examples = List[String]()
    examples.append("skill-log show")
    examples.append("skill-log show --skill diagnosing-bugs --last 5")
    examples.append("skill-log show --unresolved --json")
    return examples^


def show_value_flags() -> List[String]:
    """The flags that consume the next argument.

    The dispatcher reads this to tell `--run -h` (a run named `-h`) from a
    help request, the same way `add --problem -h` records the text `-h`.
    """
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
    """The paragraph between the usage line and the examples.

    The things a caller has to know before running the verb: what the
    order is, what `--run` matches, and that a read never writes.
    """
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
    """The flags `show` accepts.

    `given_*` records which filters the caller named, so an empty value
    can be told from an absent flag: `--skill ""` is a mistake, while
    no `--skill` at all is simply no filter.
    """

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
    """The `--last` value, as a count.

    An integer from 1 to 500. Anything else — a non-number, a number
    below one, a number above the cap — is a usage error, not a silently
    clamped value: a caller who asked for 5000 rows and got 500 would
    read the wrong log.

    The error names the range, so the one line that reports it is also
    the line that says what to write instead.
    """
    if text == "":
        raise Error("usage: " + last_range_message())
    for c in text.codepoints():
        var code = Int(c)
        if code < 48 or code > 57:
            raise Error("usage: " + last_range_message())
    # The cap is checked as the digits are consumed, so a number with
    # more digits than an Int holds cannot wrap into the valid range.
    var value = 0
    for c in text.codepoints():
        value = value * 10 + (Int(c) - 48)
        if value > LAST_MAX:
            raise Error("usage: " + last_range_message())
    if value < LAST_MIN:
        raise Error("usage: " + last_range_message())
    return value


def last_range_message() -> String:
    """The one line that says what `--last` accepts.

    The range, in one phrase, so the reader never has to guess what
    number the tool wanted.
    """
    return "--last takes a number between 1 and 500"


def parse_options(args: List[String]) raises -> Options:
    """Read `show`'s flags.

    An unknown flag, a missing value or an empty filter value is a usage
    error, raised as a `usage` marker the caller turns into exit 2: one
    line, the examples, and nothing read.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--skill":
            options.skill = take_value(args, i, "--skill", "a name")
            options.given_skill = True
            i += 1
        elif arg == "--machine":
            options.machine = take_value(args, i, "--machine", "a name")
            options.given_machine = True
            i += 1
        elif arg == "--harness":
            options.harness = take_value(args, i, "--harness", "a name")
            options.given_harness = True
            i += 1
        elif arg == "--repo":
            options.repo = take_value(args, i, "--repo", "a name")
            options.given_repo = True
            i += 1
        elif arg == "--run":
            options.run = take_value(args, i, "--run", "an id")
            options.given_run = True
            i += 1
        elif arg == "--db":
            options.db = take_value(args, i, "--db", "a path")
            i += 1
        elif arg == "--last":
            options.last = parse_last(take_value(args, i, "--last", "a number"))
            i += 1
        elif arg == "--unresolved":
            options.unresolved = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    # An empty filter value selects nothing, which is never what the
    # caller meant: `--skill ""` is a mistake, not a filter. It is a
    # usage error rather than a silently empty result.
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
    """What the table prints when nothing matched.

    The plain case names the log. A filtered case names every filter
    that was given, so a reader who asked for one harness and got
    nothing learns that the harness was the reason — and not that the
    log is empty, which it is not.
    """
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
        # No filter was given, so the log itself is empty.
        return "no invocations logged yet"

    var out = "no invocations match "
    for i in range(len(parts)):
        if i > 0:
            out += " and "
        out += parts[i]
    return out


# The table's columns, in the order they are printed. Each one is the
# row's own field, rendered for a person.
#
# A function rather than a constant: a `comptime` array of strings
# cannot be materialized at run time on this toolchain, and the table
# walks the headers at run time.
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
    """One table cell: the row's field, rendered for a person.

    Every field is sanitized the way the store sanitizes it, so a
    control character can never split a row into two lines or inject a
    terminal escape. The worktree is shortened under the home
    directory; the rest are printed as they are.
    """
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
    """The width of every column: the widest cell in it, header included.

    The header sets the floor, so a column of empty values still has a
    name over it.
    """
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
    """The table for a person: a header row, one line per invocation, and
    each problem indented under its invocation.

    The lines are joined by newlines and the last one carries none:
    `main` prints the text, so a trailing newline would leave a blank
    line behind.
    """
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
        # Empty columns in the middle of the row still pad, so the right
        # edge is trimmed: trailing spaces are noise no reader needs.
        lines.append(String(line.rstrip()))
        for p in range(len(rows[r].problems)):
            lines.append(
                "    problem " + String(p + 1) + ": " + rows[r].problems[p]
            )

    return join_lines(lines)


def handle_show(args: List[String]) raises -> Outcome:
    """The `show` handler.

    Returns the text to print on stdout, or the failure to report. It
    never prints and never exits: `main` owns both.
    """
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            # One named line, and exit 2: the line says what is wrong
            # with the call and what to write instead. The full usage
            # block is one `show --help` away, and the same shape every
            # verb's usage error has.
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
        return Outcome.fail(
            "cannot read the store: " + path + ": " + String(e), EXIT_FAILURE()
        )

    if opened.refusal.refused():
        var failure = opened.refusal.failure()
        return Outcome.fail(failure.message, failure.code)

    var rows = List[Invocation]()
    if opened.db:
        var db = opened.db.take()
        try:
            # An existing file with no store tables yet (a fresh, empty
            # SQLite file) is an empty log, not a foreign one: the store
            # layer accepts it, and only a file that already holds
            # something else was refused above.
            if is_skill_log_store(db):
                rows = read_invocations(db, filters)
        except e:
            # The store classifies the failure and this handler renders
            # it: damage is damage, a lock is a lock, and nothing here
            # inspects a SQLite message (SPEC §3).
            var failure = read_failure(path, String(e))
            return Outcome.fail(failure.message, failure.code)

    if len(rows) == 0:
        if options.json:
            # The JSON stream stays parseable: an empty result prints
            # nothing at all, not an empty object.
            return Outcome.ok("")
        return Outcome.ok(empty_message(filters))

    if options.json:
        var lines = List[String]()
        for i in range(len(rows)):
            lines.append(render_row_json(rows[i]))
        return Outcome.ok(join_lines(lines))

    return Outcome.ok(render_table(rows))
