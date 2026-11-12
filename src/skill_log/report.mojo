"""The `report` verb: name the rows a change fixes.

A change closes logged friction by committing a report that names the
invocations it addresses. The report is the transport: a squash merge
keeps tree content byte-for-byte, so a file in the tree survives the
merge, while a commit message can be rebuilt by the forge.

## Two modes, one switch

- **Artifact mode** — the checkout carries `.skill-log/reports/` (ADR-0002
  renamed it from `fixes/`; `setup` creates it). `report` unions the
  selected markers into `.skill-log/reports/<slug>.md`, one marker per
  line, replacing the file atomically. `<slug>` is the branch name,
  lowercased and reduced to `[a-z0-9._-]`, or `--slug`.
- **Trailer mode** — the checkout has no report directory. Nothing is
  written: `report` prints the `Skill-log-Fix:` trailer to put in the
  commit body, comma-separated, one line, ready to paste.

`report` never creates the report directory. Its presence is the mode
switch, and a command that created it would silently change which flow a
repo uses.

## Selection

`--id` names local rows and is repeatable, `--run` matches a row's
session, T3 thread or parent (one dispatched tree), and `--skill` names
a skill. Selectors combine with AND. No selector at all is a usage error
that carries an example.

Every selected row is checked against this store: an `--id` the store
does not have is a failure naming it, and a row that already carries a
fix commit is skipped and reported on stderr instead of being written
again.

## What reaches the file

Markers, and only markers. `machine#id` names a row from outside the
store — the machine is required because ids are per store — and the file
carries nothing else: no problem text, no project, no model. A new
selection is unioned with what the file already holds, so a second call
for the same change adds to the report instead of replacing it.

Re-running over an unchanged report writes nothing and says it is
already reported. Two `report` calls at the same instant are not
serialized: each writes a complete file and the later rename wins, so a
marker the earlier one added can be lost. Authoring one change is one
person's step, so the file is replaced atomically but not locked.

## Checking

`--check` validates the branch's report without writing: a line that is
not a marker is a problem (exit 1), and a marker this store does not own,
or one already resolved, is a warning (exit 0) — the row may live on a
machine this store has not seen. Without a store (a fresh clone, CI) the
syntax is still checked.
"""

from std.pathlib import Path

from sqlite.db import Database

from skill_log.detect import git_branch, git_toplevel
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.files import read_text, write_text
from skill_log.flags import parse_positive, take_value
from skill_log.json import json_bool, json_string, json_string_array
from skill_log.markers import Marker, marker_text, parse_marker
from skill_log.store import (
    damaged_failure,
    Filters,
    Invocation,
    StoreOpen,
    is_corruption,
    is_skill_log_store,
    open_read,
    read_invocation,
    read_invocations,
    resolve_db,
)
from skill_log.text import prefixed, sanitize

# The report directory, relative to the checkout's root. Its presence is
# what puts a checkout in artifact mode; its absence is trailer mode.
comptime REPORT_DIR = ".skill-log/reports"

# The commit-body trailer a checkout without the report directory uses.
comptime TRAILER_KEY = "Skill-log-Fix"

# The longest file-name slug. A branch name can be long; a report name
# does not need to be.
comptime MAX_SLUG = 80


def report_usage() -> String:
    """The usage line, as `--help` shows it."""
    return "skill-log report (--id <n>... | --run <id> | --skill <name>)\n" \
           "                     [--slug <name>] [--check] [--dry-run]\n" \
           "                     [--json] [--db <path>]"


def report_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them."""
    var examples = List[String]()
    examples.append("skill-log report --id 42")
    examples.append("skill-log report --run ses_abc123")
    examples.append("skill-log report --skill create-skill --slug skill-fix")
    examples.append("skill-log report --check")
    return examples^


def report_value_flags() -> List[String]:
    """The flags that consume the next argument."""
    var flags = List[String]()
    flags.append("--id")
    flags.append("--run")
    flags.append("--skill")
    flags.append("--slug")
    flags.append("--db")
    return flags^


def report_notes() -> String:
    """The paragraph between the usage line and the examples."""
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

    A branch name may carry `/`, spaces or unicode; a file name may not
    usefully. Every run of characters outside `[a-z0-9._-]` becomes one
    `-`, leading and trailing `.`/`-` are dropped, and the result is cut
    to `MAX_SLUG`. The same rule the reference used, so an existing
    report keeps its name after the port.
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
    """`text` without leading or trailing `.` and `-`.

    The slug's alphabet is ASCII, so a byte walk is the code-point walk.
    """
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


# ----------------------------------------------------------------- lists


def contains_int(items: List[Int], value: Int) -> Bool:
    """True when `value` is in `items`."""
    for i in range(len(items)):
        if items[i] == value:
            return True
    return False


def add_sorted(items: List[String], value: String) -> List[String]:
    """`items` plus `value`, sorted and without a duplicate.

    Insertion rather than `sort`: Mojo 1.2's `List` has no sort and no
    `std.algorithm` ordering, and these lists are tiny (one marker per
    resolved row).
    """
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


# -------------------------------------------------------------- selection


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
    """Read `report`'s flags.

    An unknown flag, a missing or empty value, a malformed id or no
    selector at all is a usage error, raised as a `usage` marker the
    caller turns into exit 2. The no-selector error carries an example,
    because the caller has not told the tool what to select and the
    answer is how to.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--id":
            options.ids.append(
                parse_positive(
                    take_value(args, i, "--id", "an id"),
                    "--id takes a positive integer",
                )
            )
            i += 1
        elif arg == "--run":
            options.run = take_value(args, i, "--run", "an id")
            options.given_run = True
            i += 1
        elif arg == "--skill":
            options.skill = take_value(args, i, "--skill", "a name")
            options.given_skill = True
            i += 1
        elif arg == "--slug":
            options.slug = take_value(args, i, "--slug", "a name")
            options.given_slug = True
            i += 1
        elif arg == "--db":
            options.db = take_value(args, i, "--db", "a path")
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
    """What the selectors found: markers to write, rows already closed,
    and ids the store does not have.

    `missing` is a failure, not an empty selection: a caller who named an
    id expects that row in the report, and silently writing four of five
    markers is worse than refusing.
    """

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
    var text = marker_text(row)
    if row.fix != "":
        resolved.append(text)
    else:
        pending.append(text)


def select_markers(db: Database, options: Options) raises -> Selection:
    """The markers the selectors name, split into pending and resolved.

    `--id` rows are looked up one by one, so a missing id is named even
    when the other selectors would have excluded it. The other selectors
    then narrow the named ids the same way they narrow a plain `--run` or
    `--skill` cut. A query with no id list reads every matching row, with
    no hidden limit: a report is not a preview.
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
    # Zero means every matching row; the report must not cap a selection.
    filters.limit = 0
    var rows = read_invocations(db, filters)
    for i in range(len(rows)):
        record_row(rows[i], selection.pending, selection.resolved)
    return selection^


# ---------------------------------------------------------------- reports


struct ExistingReport(Movable):
    """What a report file already holds, and the lines it cannot read."""

    var markers: List[String]
    var bad: List[String]

    def __init__(out self):
        self.markers = List[String]()
        self.bad = List[String]()


def parse_report(text: String, relative: String) -> ExistingReport:
    """The markers in a report's text, plus any line that is not one.

    A report is tool-owned: every non-blank line is a marker. A line that
    is not one is reported with its position rather than dropped, because
    rewriting the file would otherwise delete whatever a person wrote
    there without a word.
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
    """The write path's flat JSON object.

    `path` is empty and `trailer` carries the line in trailer mode; the
    keys are the same in both modes, so a consumer reads one shape.
    """
    var out = "{\"path\":" + json_string(path)
    out += ",\"markers\":" + json_string_array(markers)
    out += ",\"already_resolved\":" + json_string_array(resolved)
    out += ",\"already_reported\":" + json_bool(already)
    out += ",\"dry_run\":" + json_bool(dry_run)
    out += ",\"trailer\":" + json_string(trailer)
    out += "}"
    return out


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
    """Trailer mode: print the line, write nothing.

    The line is the transport here. The note says why nothing was written
    and where the line belongs, so the caller does not go looking for a
    file that this checkout does not have.
    """
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


# ----------------------------------------------------------------- checks


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
    """Check every line of a report against the marker grammar and the store.

    A marker this store does not hold is a warning: it names a row on a
    machine whose store has not been merged here, and that machine will
    resolve it. An already-resolved row is a warning too. A line that is
    not a marker is a problem — the merge cannot interpret it.
    """
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
            return Outcome.ok(
                "{\"path\":\"\",\"markers\":[],\"problems\":[],\"warnings\":[]}"
            )
        return Outcome.ok(
            "no "
            + REPORT_DIR
            + "/ here: this checkout resolves from the "
            + TRAILER_KEY
            + " trailer"
        )

    if not Path(path).is_file():
        if as_json:
            return Outcome.ok(
                "{\"path\":"
                + json_string(relative)
                + ",\"markers\":[],\"problems\":[],\"warnings\":[]}"
            )
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
        # A table-less (or unreadable) store still lets the syntax be
        # checked: the marker lookup is what it cannot answer.
        try:
            if is_skill_log_store(opened.db.value()):
                have_store = True
        except e:
            store_warning.append("store unavailable: " + String(e))

    var result = CheckResult()
    try:
        var text = read_text(path)
        result = validate_report(text, relative, opened, have_store)
    except e:
        if is_corruption(String(e)):
            return Outcome.fail(
                damaged_failure(store_path).message, EXIT_FAILURE()
            )
        return Outcome.fail(
            "cannot read the report: " + path + ": " + String(e), EXIT_FAILURE()
        )

    var warnings = List[String]()
    for i in range(len(store_warning)):
        warnings.append(store_warning[i])
    for i in range(len(result.warnings)):
        warnings.append(result.warnings[i])

    if as_json:
        var out = "{\"path\":" + json_string(relative)
        out += ",\"markers\":" + json_string_array(result.markers)
        out += ",\"problems\":" + json_string_array(result.problems)
        out += ",\"warnings\":" + json_string_array(warnings)
        out += "}"
        if len(result.problems) > 0:
            var failed = Outcome.fail_notes(
                problems_line(len(result.problems)), EXIT_FAILURE(), ""
            )
            failed.text = out
            return failed^
        return Outcome.ok(out)

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


# --------------------------------------------------------------- handler


def handle_report(args: List[String]) raises -> Outcome:
    """The `report` handler.

    Returns the text to print on stdout (plus any stderr notes), or the
    failure to report. It never prints and never exits: `main` owns both.
    """
    var options: Options
    try:
        options = parse_options(args)
    except e:
        var message = String(e)
        if message.startswith("usage: "):
            return Outcome.fail(String(message[byte=7:]), EXIT_USAGE())
        raise

    var root = git_toplevel()
    if root == "":
        return Outcome.fail(
            "report runs inside a git checkout (the report lives there)",
            EXIT_FAILURE(),
        )

    var slug_source = options.slug
    if slug_source == "":
        var branch = git_branch(root)
        # A detached HEAD is called `HEAD`, which is not a branch name;
        # an empty answer is "not a repository", which cannot happen here.
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
        return Outcome.fail(
            "cannot read the store: " + store_path + ": " + String(e),
            EXIT_FAILURE(),
        )
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
        # A store with no tables yet is an empty log: nothing matches,
        # and every named id is a missing id.
        if is_skill_log_store(db):
            selection = select_markers(db, options)
        else:
            tableless = True
    except e:
        if is_corruption(String(e)):
            var failure = damaged_failure(store_path)
            return Outcome.fail(failure.message, failure.code)
        raise

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

    # A report only carries markers that parse back to the same row.
    # `add` refuses a machine that cannot appear in one, but a row can
    # predate that check or come from another store; writing it would put
    # a line in the file no resolver can read.
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
