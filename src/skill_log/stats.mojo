"""The `stats` verb: the denominator and the friction rate."""

from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_declared_value
from skill_log.json import JsonObject
from skill_log.store import (
    GroupCount,
    StoreOpen,
    group_columns,
    is_group_column,
    is_skill_log_store,
    open_read,
    read_failure,
    read_group_counts,
)
from skill_log.settings import resolve_db
from skill_log.table import join_lines, pad, shorten_home
from skill_log.text import sanitize


def stats_usage() -> String:
    return "skill-log stats [--by <column>] [--skill <name>]\n" \
           "                    [--json] [--db <path>]"


def stats_examples() -> List[String]:
    var examples = List[String]()
    examples.append("skill-log stats")
    examples.append("skill-log stats --by model")
    examples.append("skill-log stats --by harness --skill skill-log")
    examples.append("skill-log stats --by repo --json")
    return examples^


def stats_value_flags() -> List[String]:
    var flags = List[String]()
    flags.append("--by")
    flags.append("--skill")
    flags.append("--db")
    return flags^


def stats_notes() -> String:
    return "Counts are distinct invocations, runs with at least one problem,\n" \
           "problem rows, and resolved runs; problems/invocation is the rate\n" \
           "between the last two, to two decimals.\n" \
           "\n" \
           "--by picks the cut: skill (the default), harness, model, repo,\n" \
           "worktree, machine or project. An unknown key is refused, not\n" \
           "guessed at. --by-model is kept as an alias for --by model.\n" \
           "\n" \
           "--skill narrows the whole cut to one skill.\n" \
           "\n" \
           "A store that does not exist prints the empty message and exits\n" \
           "0; --json prints nothing, so an empty stream stays parseable.\n" \
           "stats never writes: it creates no store and changes none."


def by_usage() -> String:
    return "--by takes one of " + ", ".join(group_columns())


def parse_by(value: String) raises -> String:
    """The grouping column, or a usage error listing the valid keys.

    The list is the store's own allow-list, so a key the query could not
    group by cannot get past the flag.
    """
    var key = String(value.strip())
    if not is_group_column(key):
        raise Error("usage: " + by_usage())
    return key


struct Options(Movable):
    """The flags `stats` accepts."""

    var by: String
    var skill: String
    var json: Bool
    var db: String
    var given_skill: Bool

    def __init__(out self):
        self.by = "skill"
        self.skill = ""
        self.json = False
        self.db = ""
        self.given_skill = False


def parse_options(args: List[String]) raises -> Options:
    """Read `stats`'s flags.

    An unknown flag, a missing value, an empty `--skill` or an unknown
    `--by` key is a usage error, raised as a `usage` marker the caller
    turns into exit 2: one line, no read.
    """
    var options = Options()
    var value_flags = stats_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--by":
            options.by = parse_by(
                take_declared_value(args, i, "--by", "a column", value_flags)
            )
            i += 1
        elif arg == "--by-model":
            # The rotation alias, kept so an existing call keeps working.
            options.by = "model"
        elif arg == "--skill":
            options.skill = take_declared_value(
                args, i, "--skill", "a name", value_flags
            )
            options.given_skill = True
            i += 1
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
            i += 1
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    if options.given_skill and String(options.skill.strip()) == "":
        raise Error("usage: --skill needs a name")
    var skill = String(options.skill.strip())
    options.skill = skill^
    return options^


def ratio_text(problems: Int, invocations: Int) -> String:
    """Problems per invocation, to two decimals, in integer arithmetic.

    Rounding a float here would let the table and the JSON disagree at
    the last digit on some machine. Hundredths are rounded half up from
    integers, and the same string feeds both renderings, so the number a
    reader sees is the number a pipe parses.
    """
    if invocations <= 0:
        return "0.00"
    var hundredths = (problems * 200 + invocations) // (2 * invocations)
    var whole = hundredths // 100
    var fraction = hundredths - whole * 100
    var fraction_text = String(fraction)
    if fraction < 10:
        fraction_text = "0" + fraction_text
    return String(whole) + "." + fraction_text


def empty_message(skill: String) -> String:
    """What a successful read with no rows says."""
    if skill != "":
        return "no invocations match --skill " + sanitize(skill)
    return "no invocations logged yet"


def table_headers(column: String) -> List[String]:
    var headers = List[String]()
    headers.append(column)
    headers.append("invocations")
    headers.append("with_problems")
    headers.append("problems")
    headers.append("resolved")
    headers.append("problems/invocation")
    return headers^


def cell(group: GroupCount, column: String, at: Int) -> String:
    """One table cell, by column index.

    The grouping column is the group's key: sanitized, and shortened
    under the reader's home when the cut is a worktree path.
    """
    if at == 0:
        if column == "worktree":
            return shorten_home(sanitize(group.key))
        return sanitize(group.key)
    if at == 1:
        return String(group.invocations)
    if at == 2:
        return String(group.with_problems)
    if at == 3:
        return String(group.problems)
    if at == 4:
        return String(group.resolved)
    return ratio_text(group.problems, group.invocations)


def render_table(groups: List[GroupCount], column: String) -> String:
    """The table for a person: a header and one line per group."""
    var headers = table_headers(column)

    var widths = List[Int]()
    for c in range(len(headers)):
        var width = headers[c].count_codepoints()
        for r in range(len(groups)):
            var here = cell(groups[r], column, c).count_codepoints()
            if here > width:
                width = here
        widths.append(width)

    var header = String("")
    for c in range(len(headers)):
        if c > 0:
            header += "  "
        if c == len(headers) - 1:
            header += headers[c]
        else:
            header += pad(headers[c], widths[c])

    var lines = List[String]()
    lines.append(header)
    for r in range(len(groups)):
        var line = String("")
        for c in range(len(headers)):
            if c > 0:
                line += "  "
            if c == len(headers) - 1:
                line += cell(groups[r], column, c)
            else:
                line += pad(cell(groups[r], column, c), widths[c])
        # Empty trailing cells still carry padding from their neighbours;
        # the right edge is trimmed so no line ends in spaces.
        lines.append(String(line.rstrip()))
    return join_lines(lines)


def render_json(groups: List[GroupCount], column: String) -> String:
    """One flat object per group, one per line, no trailing newline.

    The grouping column is the object's first key, under its own name,
    so a pipe can tell the cut from the object without being told.
    """
    var lines = List[String]()
    for i in range(len(groups)):
        var out = JsonObject()
        out.put(column, groups[i].key)
        out.put_int("invocations", groups[i].invocations)
        out.put_int("with_problems", groups[i].with_problems)
        out.put_int("problems", groups[i].problems)
        out.put_int("resolved", groups[i].resolved)
        out.put_raw(
            "problems_per_invocation",
            ratio_text(groups[i].problems, groups[i].invocations),
        )
        lines.append(out.render())
    return join_lines(lines)


def handle_stats(args: List[String]) raises -> Outcome:
    """The `stats` handler.

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

    var path = resolve_db(options.db)

    var opened: StoreOpen
    try:
        opened = open_read(path)
    except e:
        # The store classifies the failure and this handler renders it:
        # damage is damage, a lock is a lock, and nothing here inspects
        # a SQLite message (SPEC §3).
        var failure = read_failure(path, String(e))
        return Outcome.fail(failure.message, failure.code)

    if opened.refusal.refused():
        var failure = opened.refusal.failure()
        return Outcome.fail(failure.message, failure.code)

    var groups = List[GroupCount]()
    if opened.db:
        var db = opened.db.take()
        try:
            # An existing file with no store tables yet is an empty log,
            # not a foreign one; only a file that already holds something
            # else was refused above.
            if is_skill_log_store(db):
                groups = read_group_counts(db, options.by, options.skill)
        except e:
            # The store classifies the failure and this handler renders
            # it: damage is damage, a lock is a lock, and nothing here
            # inspects a SQLite message (SPEC §3).
            var failure = read_failure(path, String(e))
            return Outcome.fail(failure.message, failure.code)

    if len(groups) == 0:
        if options.json:
            # Nothing at all: an empty JSON-lines stream is empty.
            return Outcome.ok("")
        return Outcome.ok(empty_message(options.skill))

    if options.json:
        return Outcome.ok(render_json(groups, options.by))
    return Outcome.ok(render_table(groups, options.by))
