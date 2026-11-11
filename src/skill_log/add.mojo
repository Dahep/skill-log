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

In this ticket the row carries the invocation timestamp, the skill, the
machine and the problems. The other context columns stay at their schema
defaults; a later ticket fills them.

The output is the row's marker, `machine#id`, on stdout. `--json` emits
the whole row flat, and `--dry-run` prints the row it would write and
writes nothing.
"""

from skill_log.context import hostname, preview_timestamp
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

    def __init__(out self):
        self.skill = ""
        self.problems = List[String]()
        self.dry_run = False
        self.json = False
        self.db = ""


def parse_options(args: List[String]) raises -> Options:
    """Read `add`'s flags.

    `--problem` is repeatable and `--db` takes a path. An unknown flag or
    a missing value is a usage error, raised as a `usage` marker the
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

    var path = resolve_db(options.db)

    # The row as it will be written. The context columns beyond the
    # timestamp, the skill and the machine stay at their defaults until
    # a later ticket fills them.
    var row = Invocation()
    row.skill = String(options.skill.strip())
    row.machine = hostname()

    # The problems are sanitized on the way in as well as on the way
    # out: a control character in a problem must never reach the store
    # and come back as two lines.
    var problems = List[String]()
    for i in range(len(options.problems)):
        problems.append(sanitize(options.problems[i]))

    if options.dry_run:
        # The row it would write, and nothing on disk. The timestamp is
        # read through an in-memory database, so a preview never creates
        # the store.
        row.ts = preview_timestamp()
        row.problems = problems^
        return Outcome.ok(render_json(row))

    try:
        var written = write_invocation(path, row, problems)
        row.id = written
        row.problems = problems^
        if options.json:
            return Outcome.ok(render_json(row))
        return Outcome.ok(row.marker())
    except e:
        var failure = classify(path, String(e))
        return Outcome.fail(failure.message, failure.code)
