"""The `resolve` verb: the manual escape hatch.

`resolve` stamps one local row with the commit that carries its fix and
the time it was resolved. The normal path is `report` plus the post-merge
hook (#15): the report names the rows, the merged commit carries it, and
the hook stamps them. This verb is for the case the hook cannot cover —
history that was rewritten, a report that landed before the hook existed,
a row whose change shipped outside the report flow.

## What it guarantees

- The commit and the timestamp are written together, inside one
  transaction, so a row is either fully resolved or untouched.
- Repeating the same call changes nothing. The row already carries that
  fix, so the stored resolution time stays the one the first call wrote;
  a retry does not move history forward.
- A different commit corrects the resolution, with a fresh timestamp:
  re-resolving is how a wrong commit is put right.
- `--dry-run` previews the same answer and writes nothing: it reads the
  row through a read connection and the clock through the same store, so
  the previewed timestamp is the one a real call would write.
- An unknown id is named, and a store that is not there is a named
  failure rather than a silent creation — this verb never makes a store.

Output is the row's marker and the commit, because the marker is how the
row is named from outside the store. `--json` carries the same facts flat.
"""

from std.pathlib import Path

from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import parse_positive, take_value
from skill_log.json import JsonObject
from skill_log.markers import marker_text
from skill_log.store import ResolvedRow, resolve_db, resolve_row
from skill_log.text import sanitize


def resolve_usage() -> String:
    """The usage line, as `--help` shows it."""
    return "skill-log resolve --id <n> --fix <commit> [--dry-run]\n" \
           "                      [--json] [--db <path>]"


def resolve_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them."""
    var examples = List[String]()
    examples.append("skill-log resolve --id 42 --fix a1b2c3d")
    examples.append("skill-log resolve --id 42 --fix a1b2c3d --dry-run")
    examples.append("skill-log resolve --id 42 --fix a1b2c3d --json")
    return examples^


def resolve_value_flags() -> List[String]:
    """The flags that consume the next argument."""
    var flags = List[String]()
    flags.append("--id")
    flags.append("--fix")
    flags.append("--db")
    return flags^


def resolve_notes() -> String:
    """The paragraph between the usage line and the examples."""
    return "The commit is the squash merge's hash, and the time is now —\n" \
           "run it after the merge, not when the fix is authored. This is\n" \
           "the manual path: the post-merge hook resolves the rows a report\n" \
           "names without anyone remembering.\n" \
           "\n" \
           "Repeating the same call changes nothing; the first stamp's time\n" \
           "stays. A different --fix corrects the resolution with a fresh\n" \
           "timestamp.\n" \
           "\n" \
           "--dry-run previews the stamp and writes nothing. resolve never\n" \
           "creates a store: an unknown id and a missing store are named\n" \
           "failures."


struct Options(Movable):
    """The flags `resolve` accepts."""

    var id: Int
    var fix: String
    var dry_run: Bool
    var json: Bool
    var db: String

    def __init__(out self):
        self.id = 0
        self.fix = ""
        self.dry_run = False
        self.json = False
        self.db = ""


def parse_options(args: List[String]) raises -> Options:
    """Read `resolve`'s flags.

    `--id` and `--fix` are both required; an unknown flag or a missing
    value is a usage error, raised as a `usage` marker the caller turns
    into exit 2.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--id":
            options.id = parse_positive(
                take_value(args, i, "--id", "an id"),
                "--id takes a positive integer",
            )
            i += 1
        elif arg == "--fix":
            options.fix = take_value(args, i, "--fix", "a commit")
            i += 1
        elif arg == "--db":
            options.db = take_value(args, i, "--db", "a path")
            i += 1
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    if options.id == 0:
        raise Error("usage: --id needs an id")
    var fix = String(options.fix.strip())
    if fix == "":
        raise Error("usage: --fix needs a commit")
    if sanitize(fix) != fix:
        raise Error("usage: --fix takes one line: a commit or a ref")
    options.fix = fix^
    return options^


def render_json(options: Options, row: ResolvedRow) -> String:
    """The resolved row as one flat JSON object."""
    var out = JsonObject()
    out.put_int("id", options.id)
    out.put("marker", marker_text(row.machine, options.id))
    out.put("skill", row.skill)
    out.put("fix", row.fix)
    out.put("resolved_at", row.resolved_at)
    out.put_bool("changed", row.changed)
    out.put_bool("dry_run", options.dry_run)
    return out.render()


def handle_resolve(args: List[String]) raises -> Outcome:
    """The `resolve` handler.

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
    if not Path(path).is_file():
        return Outcome.fail(
            "no store at " + path + " (add a row first)", EXIT_FAILURE()
        )

    var row: ResolvedRow
    try:
        row = resolve_row(path, options.id, options.fix, options.dry_run)
    except e:
        # The store classifies the failure and raises its named message
        # (SPEC §3); this handler adds nothing to it.
        return Outcome.fail(String(e), EXIT_FAILURE())

    if row.refusal.refused():
        var failure = row.refusal.failure()
        return Outcome.fail(failure.message, failure.code)
    if not row.found:
        return Outcome.fail(
            "no invocation " + String(options.id) + " in " + path, EXIT_FAILURE()
        )

    if options.json:
        return Outcome.ok(render_json(options, row))

    var marker = marker_text(row.machine, options.id)
    if not row.changed:
        return Outcome.ok(marker + " already resolved: " + options.fix)
    if options.dry_run:
        return Outcome.ok(marker + " would resolve: " + options.fix)
    return Outcome.ok(marker + " resolved: " + options.fix)
