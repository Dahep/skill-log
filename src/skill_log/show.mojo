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
exit 0.

A damaged, foreign, older or newer store is named once on stderr and
exits 1. A read never creates the store, the state directory or an empty
database.
"""

from std.os import getenv

from skill_log.errors import Outcome
from skill_log.render import render_row_json
from skill_log.store import (
    DEFAULT_LIMIT,
    Filters,
    Invocation,
    classify,
    open_read,
    read_invocations,
    resolve_db,
    sanitize,
)

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
           "--last takes a number between 1 and 500, 20 by default.\n" \
           "\n" \
           "--json prints one flat object per line, with every column,\n" \
           "the marker and the problems. An empty log prints nothing at\n" \
           "all, so the stream stays valid JSON lines.\n" \
           "\n" \
           "A read never writes: it creates no store and changes none."


def show_usage_block() -> String:
    """The block a usage error prints: the usage line and the examples.

    A usage error is one named line plus this block: the line says what
    is wrong with the call, and the block says how to make a call that
    works.
    """
    var text = "usage:\n  " + show_usage() + "\n"
    text += "\nexamples:\n"
    var examples = show_examples()
    for i in range(len(examples)):
        text += "  " + examples[i] + "\n"
    return text


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
    """
    if text == "":
        raise Error("usage: --last takes a number")
    for c in text.codepoints():
        var code = Int(c)
        if code < 48 or code > 57:
            raise Error("usage: --last takes a number")
    var value = 0
    for c in text.codepoints():
        value = value * 10 + (Int(c) - 48)
    if value < LAST_MIN:
        raise Error("usage: --last must be 1 or more")
    if value > LAST_MAX:
        raise Error("usage: --last is capped at 500")
    return value


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
            i += 1
            if i >= len(args):
                raise Error("usage: --skill needs a name")
            options.skill = String(args[i])
            options.given_skill = True
        elif arg == "--machine":
            i += 1
            if i >= len(args):
                raise Error("usage: --machine needs a name")
            options.machine = String(args[i])
            options.given_machine = True
        elif arg == "--harness":
            i += 1
            if i >= len(args):
                raise Error("usage: --harness needs a name")
            options.harness = String(args[i])
            options.given_harness = True
        elif arg == "--repo":
            i += 1
            if i >= len(args):
                raise Error("usage: --repo needs a name")
            options.repo = String(args[i])
            options.given_repo = True
        elif arg == "--run":
            i += 1
            if i >= len(args):
                raise Error("usage: --run needs an id")
            options.run = String(args[i])
            options.given_run = True
        elif arg == "--db":
            i += 1
            if i >= len(args):
                raise Error("usage: --db needs a path")
            options.db = String(args[i])
        elif arg == "--last":
            i += 1
            if i >= len(args):
                raise Error("usage: --last needs a number")
            options.last = parse_last(String(args[i]))
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


def empty_message(skill: String, machine: String) -> String:
    """What the table prints when nothing matched.

    The plain case names the log; the filtered cases name the filter, so
    a reader who asked for one skill and got nothing knows the filter
    was the reason.
    """
    if skill != "" and machine != "":
        return "no invocations match --skill " + skill + " on machine " + machine
    if skill != "":
        return "no invocations match --skill " + skill
    if machine != "":
        return "no invocations from machine " + machine
    return "no invocations logged yet"


def home_prefix() -> String:
    """The home directory with a trailing separator, or an empty string.

    An empty home yields an empty prefix, so no path is ever shortened
    against a home the machine does not have.
    """
    var home = getenv("HOME", "")
    if home == "":
        return ""
    if home.endswith("/"):
        return home
    return home + "/"


def shorten(path: String) -> String:
    """The path with the home directory replaced by `~`.

    A path outside the home is returned unchanged. The home is the one
    the reader's own environment names, so the same row reads the same
    way for every reader on the machine.
    """
    var home = home_prefix()
    if home == "":
        return path
    if path.startswith(home):
        return "~/" + String(path[byte=home.byte_length():])
    return path


def render_json(row: Invocation) -> String:
    """One row as a flat JSON object.

    The shape is the one `add --json` writes, so a consumer that reads
    one of them reads the other: every ADR-0002 column is flat, plus the
    marker and the problems array, in a fixed key order.
    """
    return render_row_json(row)


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
        return shorten(sanitize(row.worktree))
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
        widths.append(headers[i].byte_length())
    for r in range(len(rows)):
        for c in range(len(headers)):
            var text = cell(rows[r], headers[c])
            if text.byte_length() > widths[c]:
                widths[c] = text.byte_length()
    return widths^


def pad(text: String, width: Int) -> String:
    """The text, padded to the column's width.

    The last column is not padded: trailing spaces are noise at the end
    of a line.
    """
    var out = text
    while out.byte_length() < width:
        out += " "
    return out


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
        lines.append(line)
        for p in range(len(rows[r].problems)):
            lines.append(
                "    problem " + String(p + 1) + ": " + rows[r].problems[p]
            )

    return join_lines(lines)


def join_lines(lines: List[String]) -> String:
    """The lines, separated by newlines, with no trailing newline."""
    var out = ""
    for i in range(len(lines)):
        if i > 0:
            out += "\n"
        out += lines[i]
    return out


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
            # One named line, then the usage block: the line says what
            # is wrong with the call, the block says how to make a call
            # that works.
            return Outcome.usage_error_with(
                String(message[byte=7:]), show_usage_block()
            )
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

    var rows = List[Invocation]()
    try:
        var db = open_read(path)
        if db is not None:
            rows = read_invocations(db.value(), filters)
    except e:
        var failure = classify(path, String(e))
        return Outcome.fail(failure.message, failure.code)

    if len(rows) == 0:
        if options.json:
            # The JSON stream stays parseable: an empty result prints
            # nothing at all, not an empty object.
            return Outcome.ok("")
        return Outcome.ok(empty_message(filters.skill, filters.machine))

    if options.json:
        var lines = List[String]()
        for i in range(len(rows)):
            lines.append(render_json(rows[i]))
        return Outcome.ok(join_lines(lines))

    return Outcome.ok(render_table(rows))
