"""The `report` verb: name the rows a change fixes."""

from std.pathlib import Path

from sqlite.db import Database

from skill_log.git import git_branch, git_toplevel
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.files import read_text, write_text
from skill_log.flags import parse_positive, take_declared_value
from skill_log.json import JsonObject
from skill_log.markers import marker_text, parse_marker
from skill_log.store import (
    Filters,
    Invocation,
    StoreOpen,
    is_skill_log_store,
    open_read,
    read_failure,
    read_invocation,
    read_invocations,
)
from skill_log.settings import resolve_db
from skill_log.text import prefixed, sanitize

comptime REPORT_DIR = ".skill-log/reports"

comptime README_NAME = "README.md"
comptime KEEP_NAME = ".keep"


def report_dir_readme() -> String:
    """The README `setup` writes into a new report directory."""
    return """\
# .skill-log/reports

The report a change commits when it fixes friction recorded in the local
skill log. Resolution reads it after the merge, so the fix cannot be
forgotten.

- `<slug>.md` — one report per fix change, one `machine#id` per line.
  `skill-log report --id …` writes it (and validates the ids against the
  local log); commit it with the change.
- `resolve-merged` (the `post-merge` hook) reads the files a pull added or
  changed and stamps each named row with the commit that carries it. Each
  machine resolves only the rows it owns; a row named for another machine
  is reported there and resolves on that machine's next pull.

A repo without this directory still uses the commit-body
`Skill-log-Fix:` trailer. This directory is the transport for repos that
have it, because a squash merge keeps tree content exactly as committed.
"""

comptime TRAILER_KEY = "Skill-log-Fix"

comptime MAX_SLUG = 80


def report_usage() -> String:
    return "skill-log report (--id <n>... | --run <id> | --skill <name>)\n" \
           "                     [--slug <name>] [--check] [--dry-run]\n" \
           "                     [--json] [--db <path>]"


def report_examples() -> List[String]:
    var examples = List[String]()
    examples.append("skill-log report --id 42")
    examples.append("skill-log report --run ses_abc123")
    examples.append("skill-log report --skill create-skill --slug skill-fix")
    examples.append("skill-log report --check")
    return examples^


def report_value_flags() -> List[String]:
    var flags = List[String]()
    flags.append("--id")
    flags.append("--run")
    flags.append("--skill")
    flags.append("--slug")
    flags.append("--db")
    return flags^


def report_notes() -> String:
    return "The report is the transport: .skill-log/reports/<branch>.md,\n" \
           "one machine#id per line, committed with the change. Markers are\n" \
           "unioned with what the file already holds, and never carry problem\n" \
           "text or project details.\n" \
           "\n" \
           "A checkout without .skill-log/reports/ writes nothing: report\n" \
           "prints the Skill-log-Fix trailer to put in the commit body.\n" \
           "\n" \
           "Ids are validated here, at authoring time: an id this store does\n" \
           "not have is refused, and an already-resolved row is skipped and\n" \
           "named. --check validates the branch's report without writing;\n" \
           "--dry-run previews the write."


def branch_slug(branch: String) -> String:
    """The report file's name for a branch: lowercase, safe, truncated.

    Every run of characters outside `[a-z0-9._-]` becomes one `-`, leading
    and trailing `.`/`-` are dropped, and the result is cut to `MAX_SLUG`.
    """
    var lower = branch.strip().lower()
    var out = String("")
    var pending_dash = False
    for c in lower.codepoints():
        var ch = String(c)
        var code = Int(c)
        var keep = (
            (code >= 97 and code <= 122)
            or (code >= 48 and code <= 57)
            or ch == "."
            or ch == "_"
            or ch == "-"
        )
        if keep:
            if pending_dash and out != "":
                out += "-"
            out += ch
            pending_dash = False
        else:
            pending_dash = True
    var trimmed = trim_slug(out)
    if trimmed.byte_length() > MAX_SLUG:
        return String(trimmed[byte=0:MAX_SLUG])
    return trimmed


def trim_slug(text: String) -> String:
    """`text` without leading or trailing `.` and `-`."""
    var src = text.unsafe_ptr()
    var start = 0
    var stop = text.byte_length()
    while start < stop and (
        Int(src[unsafe_offset=start]) == 45
        or Int(src[unsafe_offset=start]) == 46
    ):
        start += 1
    while stop > start and (
        Int(src[unsafe_offset=stop - 1]) == 45
        or Int(src[unsafe_offset=stop - 1]) == 46
    ):
        stop -= 1
    return String(text[byte=start:stop])




def contains_int(items: List[Int], value: Int) -> Bool:
    """True when `value` is in `items`."""
    for i in range(len(items)):
        if items[i] == value:
            return True
    return False


def add_sorted(items: List[String], value: String) -> List[String]:
    """`items` plus `value`, sorted and without a duplicate."""
    var out = List[String]()
    var placed = False
    for i in range(len(items)):
        if not placed and value < items[i]:
            out.append(value)
            placed = True
        if items[i] != value:
            out.append(items[i])
    if not placed:
        out.append(value)
    return out^


def sorted_unique(items: List[String]) -> List[String]:
    """`items` deduplicated and sorted."""
    var out = List[String]()
    for i in range(len(items)):
        out = add_sorted(out, items[i])
    return out^


def join_ints(items: List[Int]) -> String:
    """The ids, comma-separated, for one diagnostic line."""
    var parts = List[String]()
    for i in range(len(items)):
        parts.append(String(items[i]))
    return ", ".join(parts)


def problems_line(count: Int) -> String:
    """The one failure line for a report with `count` bad lines."""
    if count == 1:
        return "report check failed: 1 line is not a marker"
    return "report check failed: " + String(count) + " lines are not markers"


def marker_count(count: Int) -> String:
    """`1 marker` or `N markers`."""
    if count == 1:
        return "1 marker"
    return String(count) + " markers"


def first_nine(text: String) -> String:
    """The first nine bytes of a commit hash, or the whole short hash."""
    if text.byte_length() <= 9:
        return text
    return String(text[byte=0:9])




struct Options(Movable):
    """The flags `report` accepts."""

    var ids: List[Int]
    var run: String
    var skill: String
    var slug: String
    var check: Bool
    var dry_run: Bool
    var json: Bool
    var db: String
    var given_run: Bool
    var given_skill: Bool
    var given_slug: Bool

    def __init__(out self):
        self.ids = List[Int]()
        self.run = ""
        self.skill = ""
        self.slug = ""
        self.check = False
        self.dry_run = False
        self.json = False
        self.db = ""
        self.given_run = False
        self.given_skill = False
        self.given_slug = False


def parse_options(args: List[String]) raises -> Options:
    """Read `report`'s flags."""
    var options = Options()
    var value_flags = report_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--id":
            options.ids.append(
                parse_positive(
                    take_declared_value(
                        args, i, "--id", "an id", value_flags
                    ),
                    "--id takes a positive integer",
                )
            )
            i += 1
        elif arg == "--run":
            options.run = take_declared_value(
                args, i, "--run", "an id", value_flags
            )
            options.given_run = True
            i += 1
        elif arg == "--skill":
            options.skill = take_declared_value(
                args, i, "--skill", "a name", value_flags
            )
            options.given_skill = True
            i += 1
        elif arg == "--slug":
            options.slug = take_declared_value(
                args, i, "--slug", "a name", value_flags
            )
            options.given_slug = True
            i += 1
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
            i += 1
        elif arg == "--check":
            options.check = True
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    if options.given_run and String(options.run.strip()) == "":
        raise Error("usage: --run needs an id")
    if options.given_skill and String(options.skill.strip()) == "":
        raise Error("usage: --skill needs a name")
    if options.given_slug and String(options.slug.strip()) == "":
        raise Error("usage: --slug needs a name")

    var run = String(options.run.strip())
    var skill = String(options.skill.strip())
    var slug = String(options.slug.strip())
    options.run = run^
    options.skill = skill^
    options.slug = slug^

    if not options.check and len(options.ids) == 0 \
            and options.run == "" and options.skill == "":
        raise Error(
            "usage: report needs --id, --run or --skill (or --check);"
            " for example: skill-log report --run ses_abc123"
        )
    return options^


struct Selection(Movable):
    """What the selectors found: markers to write, rows already closed, and ids the store does not have."""

    var pending: List[String]
    var resolved: List[String]
    var missing: List[Int]

    def __init__(out self):
        self.pending = List[String]()
        self.resolved = List[String]()
        self.missing = List[Int]()


def record_row(
    row: Invocation, mut pending: List[String], mut resolved: List[String]
):
    """Sort one row into the report (pending) or the skip list (resolved)."""
    var text = marker_text(row.machine, row.id)
    if row.fix != "":
        resolved.append(text)
    else:
        pending.append(text)


def select_markers(db: Database, options: Options) raises -> Selection:
    """The markers the selectors name, split into pending and resolved.

    `--id` rows are looked up one by one, so a missing id is named even when
    the other selectors would have excluded it. A query with no id list
    reads every matching row, with no hidden limit.
    """
    var selection = Selection()

    var wanted = List[Int]()
    for i in range(len(options.ids)):
        if not contains_int(wanted, options.ids[i]):
            wanted.append(options.ids[i])

    if len(wanted) > 0:
        for i in range(len(wanted)):
            var found = read_invocation(db, wanted[i])
            if not found:
                selection.missing.append(wanted[i])
                continue
            var row = found.take()
            if options.run != "" and row.session != options.run \
                    and row.t3_thread != options.run \
                    and row.parent != options.run:
                continue
            if options.skill != "" and row.skill != options.skill:
                continue
            record_row(row, selection.pending, selection.resolved)
        return selection^

    var filters = Filters()
    filters.run = options.run
    filters.skill = options.skill
    filters.limit = 0
    var rows = read_invocations(db, filters)
    for i in range(len(rows)):
        record_row(rows[i], selection.pending, selection.resolved)
    return selection^




struct ExistingReport(Movable):
    """What a report file already holds, and the lines it cannot read."""

    var markers: List[String]
    var bad: List[String]

    def __init__(out self):
        self.markers = List[String]()
        self.bad = List[String]()


def parse_report(text: String, relative: String) -> ExistingReport:
    """The markers in a report's text, plus any line that is not one.

    A report is tool-owned: every non-blank line is a marker. A line that is
    not one is reported with its position rather than dropped.
    """
    var report = ExistingReport()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var value = String(lines[i].strip())
        if value == "":
            continue
        var parsed = parse_marker(value)
        if not parsed:
            report.bad.append(
                relative
                + ":"
                + String(i + 1)
                + ": not a marker (machine#id): "
                + sanitize(value)
            )
            continue
        report.markers.append(parsed.value().text())
    return report^


def write_json(
    path: String,
    markers: List[String],
    resolved: List[String],
    already: Bool,
    dry_run: Bool,
    trailer: String,
) -> String:
    """The write path's flat JSON object."""
    var out = JsonObject()
    out.put("path", path)
    out.put_strings("markers", markers)
    out.put_strings("already_resolved", resolved)
    out.put_bool("already_reported", already)
    out.put_bool("dry_run", dry_run)
    out.put("trailer", trailer)
    return out.render()


def resolved_notes(resolved: List[String]) -> String:
    """One stderr note per row a previous change already closed."""
    var lines = List[String]()
    for i in range(len(resolved)):
        lines.append(resolved[i] + " already resolved; skipped")
    return prefixed(lines)


def nothing_outcome(options: Options, resolved: List[String], notes: String) -> Outcome:
    """The answer when the selection produced no marker to write at all."""
    if options.json:
        return Outcome.ok_notes(
            write_json("", List[String](), resolved, False, options.dry_run, ""),
            notes,
        )
    return Outcome.ok_notes(
        "nothing to report: the selected rows are already resolved", notes
    )


def trailer_outcome(
    pending: List[String], resolved: List[String], notes: String, options: Options
) -> Outcome:
    """Trailer mode: print the line, write nothing."""
    if len(pending) == 0:
        return nothing_outcome(options, resolved, notes)
    var line = TRAILER_KEY + ": " + ", ".join(pending)
    var all_notes = notes
    if all_notes != "":
        all_notes += "\n"
    all_notes += (
        "skill-log: no " + REPORT_DIR + "/ here; put the trailer in the commit body"
    )
    if options.json:
        return Outcome.ok_notes(
            write_json("", pending, resolved, False, options.dry_run, line),
            all_notes,
        )
    return Outcome.ok_notes(line, all_notes)




struct CheckResult(Movable):
    """A report's markers, the lines that are not markers, and warnings."""

    var markers: List[String]
    var problems: List[String]
    var warnings: List[String]

    def __init__(out self):
        self.markers = List[String]()
        self.problems = List[String]()
        self.warnings = List[String]()


def validate_report(
    text: String, relative: String, opened: StoreOpen, have_store: Bool
) raises -> CheckResult:
    """Check every line of a report against the marker grammar and the store."""
    var result = CheckResult()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var value = String(lines[i].strip())
        if value == "":
            continue
        var parsed = parse_marker(value)
        if not parsed:
            result.problems.append(
                relative
                + ":"
                + String(i + 1)
                + ": not a marker (machine#id): "
                + sanitize(value)
            )
            continue
        var marker = parsed.take()
        var text_marker = marker.text()
        result.markers.append(text_marker)
        if not have_store:
            continue
        var row = read_invocation(opened.db.value(), marker.id)
        if not row:
            result.warnings.append(
                text_marker + ": not in this db (resolves where it is)"
            )
            continue
        if row.value().machine != marker.machine:
            result.warnings.append(
                text_marker + ": not in this db (resolves where it is)"
            )
            continue
        if row.value().fix != "":
            result.warnings.append(
                text_marker + ": already resolved by " + first_nine(row.value().fix)
            )
    return result^


def check_outcome(
    path: String,
    relative: String,
    store_path: String,
    artifact: Bool,
    as_json: Bool,
) -> Outcome:
    """The `--check` answer: validate, never write, exit 1 on a problem."""
    if not artifact:
        if as_json:
            var empty = JsonObject()
            empty.put("path", "")
            empty.put_strings("markers", List[String]())
            empty.put_strings("problems", List[String]())
            empty.put_strings("warnings", List[String]())
            return Outcome.ok(empty.render())
        return Outcome.ok(
            "no "
            + REPORT_DIR
            + "/ here: this checkout resolves from the "
            + TRAILER_KEY
            + " trailer"
        )

    if not Path(path).is_file():
        if as_json:
            var absent = JsonObject()
            absent.put("path", relative)
            absent.put_strings("markers", List[String]())
            absent.put_strings("problems", List[String]())
            absent.put_strings("warnings", List[String]())
            return Outcome.ok(absent.render())
        return Outcome.ok("no report file at " + relative)

    var opened = StoreOpen()
    var have_store = False
    var store_warning = List[String]()
    try:
        opened = open_read(store_path)
    except e:
        store_warning.append("store unavailable: " + String(e))
    if opened.refusal.refused():
        store_warning.append(
            "store unavailable: " + opened.refusal.failure().message
        )
    elif opened.db:
        try:
            if is_skill_log_store(opened.db.value()):
                have_store = True
        except e:
            store_warning.append("store unavailable: " + String(e))

    var result = CheckResult()
    var text = String("")
    try:
        text = read_text(path)
    except e:
        return Outcome.fail(
            "cannot read the report: " + path + ": " + String(e),
            EXIT_FAILURE(),
        )
    try:
        result = validate_report(text, relative, opened, have_store)
    except e:
        var failure = read_failure(store_path, String(e))
        return Outcome.fail(failure.message, failure.code)

    var warnings = List[String]()
    for i in range(len(store_warning)):
        warnings.append(store_warning[i])
    for i in range(len(result.warnings)):
        warnings.append(result.warnings[i])

    if as_json:
        var out = JsonObject()
        out.put("path", relative)
        out.put_strings("markers", result.markers)
        out.put_strings("problems", result.problems)
        out.put_strings("warnings", warnings)
        var rendered = out.render()
        if len(result.problems) > 0:
            var failed = Outcome.fail_notes(
                problems_line(len(result.problems)), EXIT_FAILURE(), ""
            )
            failed.text = rendered
            return failed^
        return Outcome.ok(rendered)

    var notes = prefixed(warnings)
    if len(result.problems) > 0:
        var problems = List[String]()
        for i in range(len(result.problems)):
            problems.append(result.problems[i])
        var all_notes = prefixed(problems)
        if notes != "":
            all_notes += "\n" + notes
        return Outcome.fail_notes(
            relative + " is not a valid report", EXIT_FAILURE(), all_notes
        )
    return Outcome.ok_notes(
        relative + " is valid (" + marker_count(len(result.markers)) + ")", notes
    )




def handle_report(args: List[String]) raises -> Outcome:
    """The `report` handler."""
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    var root = git_toplevel("")
    if root == "":
        return Outcome.fail(
            "report runs inside a git checkout (the report lives there)",
            EXIT_FAILURE(),
        )

    var slug_source = options.slug
    if slug_source == "":
        var branch = git_branch(root)
        if branch == "HEAD" or branch == "":
            return Outcome.fail(
                "cannot name the report file (detached HEAD?); pass --slug",
                EXIT_FAILURE(),
            )
        slug_source = branch
    var slug = branch_slug(slug_source)
    if slug == "":
        return Outcome.fail(
            "cannot name the report file (detached HEAD?); pass --slug",
            EXIT_FAILURE(),
        )

    var relative = REPORT_DIR + "/" + slug + ".md"
    var path = root + "/" + relative
    var artifact = Path(root + "/" + REPORT_DIR).is_dir()
    var store_path = resolve_db(options.db)

    if options.check:
        return check_outcome(path, relative, store_path, artifact, options.json)

    var opened: StoreOpen
    try:
        opened = open_read(store_path)
    except e:
        var failure = read_failure(store_path, String(e))
        return Outcome.fail(failure.message, failure.code)
    if opened.refusal.refused():
        var failure = opened.refusal.failure()
        return Outcome.fail(failure.message, failure.code)
    if not opened.db:
        return Outcome.fail(
            "no store at " + store_path + " (run add first)", EXIT_FAILURE()
        )

    var selection = Selection()
    var tableless = False
    try:
        var db = opened.db.take()
        if is_skill_log_store(db):
            selection = select_markers(db, options)
        else:
            tableless = True
    except e:
        var failure = read_failure(store_path, String(e))
        return Outcome.fail(failure.message, failure.code)

    if tableless and len(options.ids) > 0:
        var wanted = List[Int]()
        for i in range(len(options.ids)):
            if not contains_int(wanted, options.ids[i]):
                wanted.append(options.ids[i])
        selection.missing = wanted^

    if len(selection.missing) > 0:
        return Outcome.fail(
            "no invocation " + join_ints(selection.missing) + " in " + store_path,
            EXIT_FAILURE(),
        )

    var pending = sorted_unique(selection.pending)
    var resolved = sorted_unique(selection.resolved)
    var notes = resolved_notes(resolved)

    for i in range(len(pending)):
        var parsed = parse_marker(pending[i])
        if not parsed or parsed.value().text() != pending[i]:
            return Outcome.fail(
                "cannot report "
                + sanitize(pending[i])
                + ": not a marker (machine#id)",
                EXIT_FAILURE(),
            )

    if not artifact:
        return trailer_outcome(pending, resolved, notes, options)

    var existing = ExistingReport()
    if Path(path).is_file():
        try:
            var text = read_text(path)
            existing = parse_report(text, relative)
        except e:
            return Outcome.fail(
                "cannot read the report: " + path + ": " + String(e),
                EXIT_FAILURE(),
            )
    if len(existing.bad) > 0:
        return Outcome.fail_notes(
            relative + " is not a valid report", EXIT_FAILURE(),
            prefixed(existing.bad),
        )

    var existing_sorted = sorted_unique(existing.markers)
    var existing_count = len(existing_sorted)
    var merged = existing_sorted^
    for i in range(len(pending)):
        merged = add_sorted(merged, pending[i])

    if len(merged) == 0:
        return nothing_outcome(options, resolved, notes)

    var already = existing_count > 0 and len(merged) == existing_count

    if not options.dry_run and not already:
        var text = "\n".join(merged) + "\n"
        try:
            write_text(path, text)
        except e:
            return Outcome.fail(
                "cannot write the report: " + path + ": " + String(e),
                EXIT_FAILURE(),
            )

    if options.json:
        return Outcome.ok_notes(
            write_json(relative, merged, resolved, already, options.dry_run, ""),
            notes,
        )
    if already:
        return Outcome.ok_notes(
            "already reported: " + relative + " (" + marker_count(len(merged)) + ")",
            notes,
        )
    var verb = "reported"
    if options.dry_run:
        verb = "would report"
    return Outcome.ok_notes(
        verb + " " + marker_count(len(merged)) + " in " + relative, notes
    )
