"""The `resolve-merged` verb: close the rows a pull landed.

`report` writes the markers into the change; this verb reads them back
from the commits a pull brought in and stamps each named row with the
commit that carries its fix. It is the post-merge hook's entry point, so
it is bounded, quiet, and safe to run after every pull.

## Where the markers come from

- **Artifact mode** — the checkout carries `.skill-log/reports/`. The
  report files the scanned range added or changed are read from their
  commits (the working tree may have moved on) and the newest commit
  touching each file is that file's stamp. A commit-body trailer is
  ignored and reported once, because the tree is the transport here.
- **Trailer mode** — no report directory. The last trailer block of each
  commit in the range is the report, exactly what `report` prints when a
  checkout cannot carry a file.

A commit whose body carries a marker the last-trailer-block rule did not
return — a multi-author squash puts `Co-authored-by:` in a later block —
is reported with its value instead of being dropped. A value that is not
`machine#id` is reported the same way. Both kinds reach the `ignored`
array of the `--json` answer, so a `--quiet --json` caller still learns
what the scan did not act on.

## The scan

`--since` bounds the scan to what a pull landed; the hook passes the
pre-merge reflog position. A revision git cannot resolve falls back to a
quiet full scan, because a hook that fails on a missing reflog entry
would resolve nothing. An option-shaped `--since` is a usage error: it
would otherwise reach git as an option.

Newest marker wins: the scan walks commits newest first and keeps the
first marker it sees for a row, so an amended fix supersedes an earlier
one in the same range. A row logged after the named commit is skipped
with its reason (a rebuilt log can reuse ids). Resolution is idempotent:
a second scan finds the rows already resolved and stamps nothing.

A missing store is nothing to do, exit 0: the hook runs on machines that
may never have logged a row. `--quiet` suppresses every note, `--dry-run`
reports the same answer and writes nothing, and `--json` is one stable
shape in every mode.
"""

from std.pathlib import Path
from std.subprocess import run

from skill_log.context import hostname
from skill_log.detect import git_toplevel, shell_quote
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_value
from skill_log.json import json_bool, json_string, json_string_array
from skill_log.markers import parse_marker
from skill_log.report import REPORT_DIR, TRAILER_KEY
from skill_log.store import (
    resolve_db,
    resolve_merged_rows,
    MergedResult,
    MergedSkip,
    Located,
)
from skill_log.text import prefixed, sanitize

# A field separator for the git log records. NUL cannot appear in a
# commit message or an object name, so it cannot be confused with data.
comptime FIELD = "\u0000"

# A record separator. Git commit bodies cannot carry it usefully and no
# marker does, so one `git log` call carries every commit's fields.
comptime RECORD = "\u001e"


def resolve_merged_usage() -> String:
    """The usage line, as `--help` shows it."""
    return "skill-log resolve-merged [--since <rev>] [--quiet] [--dry-run]\n" \
           "                            [--json] [--db <path>]"


def resolve_merged_examples() -> List[String]:
    """The verb's real invocations, as `--help` shows them."""
    var examples = List[String]()
    examples.append("skill-log resolve-merged")
    examples.append("skill-log resolve-merged --since HEAD@{1} --quiet")
    examples.append("skill-log resolve-merged --since origin/main~5 --dry-run --json")
    return examples^


def resolve_merged_value_flags() -> List[String]:
    """The flags that consume the next argument."""
    var flags = List[String]()
    flags.append("--since")
    flags.append("--db")
    return flags^


def resolve_merged_notes() -> String:
    """The paragraph between the usage line and the examples."""
    return "A checkout with .skill-log/reports/ resolves from the report files\n" \
           "the range added or changed; elsewhere the last trailer block of\n" \
           "each commit is the report. A later trailer block hides an\n" \
           "earlier marker, and that marker is reported, never dropped.\n" \
           "\n" \
           "--since bounds the scan to what a pull landed, which is what the\n" \
           "post-merge hook passes (the pre-merge reflog position). A range\n" \
           "git cannot resolve falls back to a quiet full scan.\n" \
           "\n" \
           "The newest marker for a row wins, a row logged after the named\n" \
           "commit is skipped with its reason, and a second scan stamps\n" \
           "nothing. A missing store is nothing to do, exit 0. --quiet\n" \
           "suppresses the notes; --dry-run writes nothing."


struct Options(Movable):
    """The flags `resolve-merged` accepts."""

    var since: String
    var quiet: Bool
    var dry_run: Bool
    var json: Bool
    var db: String

    def __init__(out self):
        self.since = ""
        self.quiet = False
        self.dry_run = False
        self.json = False
        self.db = ""


def parse_options(args: List[String]) raises -> Options:
    """Read `resolve-merged`'s flags.

    An unknown flag, a missing value or an option-shaped `--since` is a
    usage error, raised as a `usage` marker the caller turns into exit 2.
    """
    var options = Options()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--since":
            options.since = take_value(args, i, "--since", "a revision")
            i += 1
        elif arg.startswith("--since="):
            options.since = String(arg[byte=8:])
        elif arg == "--db":
            options.db = take_value(args, i, "--db", "a path")
            i += 1
        elif arg == "--quiet":
            options.quiet = True
        elif arg == "--dry-run":
            options.dry_run = True
        elif arg == "--json":
            options.json = True
        else:
            raise Error("usage: unknown option: " + arg)
        i += 1

    var since = String(options.since.strip())
    if since != "":
        # A revision reaches a shell command and git's option parser. An
        # option-shaped value would be read as an option, so it is refused
        # before either sees it.
        if since.startswith("-") or sanitize(since) != since:
            raise Error("usage: --since needs a revision")
    options.since = since^
    return options^


# --------------------------------------------------------------- scanning


struct Scan(Movable):
    """What one pass over history found: markers, bad values, hidden ones.

    `located` is the scan's yield: one `Located` per row the scan named.
    """

    var located: List[Located]
    var malformed: List[String]
    var hidden: List[String]

    def __init__(out self):
        self.located = List[Located]()
        self.malformed = List[String]()
        self.hidden = List[String]()


def contains_pair(
    located: List[Located], machine: String, id: Int
) -> Bool:
    """True when this row already has a marker in the scan."""
    for i in range(len(located)):
        if located[i].machine == machine and located[i].id == id:
            return True
    return False


def add_marker(
    mut located: List[Located],
    machine: String,
    id: Int,
    commit: String,
    epoch: Int,
):
    """Keep the first marker for a row: newest wins, oldest is ignored.

    The scan walks commits newest first, so the first marker it meets is
    the newest commit that names the row.
    """
    if contains_pair(located, machine, id):
        return
    var marker = Located(machine, id, commit, epoch)
    located.append(marker^)


def git_output(dir: String, args: String) -> String:
    """Run one git command in `dir` and return its exact stdout.

    The command string is built from constants and shell-quoted values;
    stderr is discarded so a range git cannot read is a quiet empty
    answer rather than noise on a pull.
    """
    var command = "git -C " + shell_quote(dir) + " " + args + " 2>/dev/null"
    try:
        var out = run(command)
        return String(out)
    except:
        return ""


def git_commit(root: String, revision: String) -> String:
    """The commit `revision` names, or an empty string.

    This is the bound check: a reflog position that does not exist is
    not an error here, it is a missing bound, and the caller falls back
    to a full scan.
    """
    var args = "rev-parse --verify " + shell_quote(revision + "^{commit}")
    return String(git_output(root, args).strip())


def body_trailer_values(body: String) -> List[String]:
    """Every marker the body's `Skill-log-Fix:` lines carry, in body order.

    The scan is line-based and prefix-based, like the marker grammar
    itself: a line whose first characters are the key, then a colon,
    then the value. A prose mention of the key in the middle of a
    paragraph is not a marker.

    A line may hold several comma-separated markers — the trailer
    grammar allows it — so the line's value is split into its pieces
    here. Both sides of the comparison are then one marker each, which
    is the only way "did the parser return this one?" has an answer.
    """
    var values = List[String]()
    var key = TRAILER_KEY.lower()
    for line in body.split("\n"):
        var text = String(line.strip())
        var lower = text.lower()
        if not lower.startswith(key):
            continue
        var rest = String(text[byte=key.byte_length():])
        var trimmed = String(rest.strip())
        if trimmed == "" or not trimmed.startswith(":"):
            continue
        var value = String(trimmed[byte=1:].strip())
        if value == "":
            continue
        for piece in value.split(","):
            var marker = String(piece.strip())
            if marker != "":
                values.append(sanitize(marker))
    return values^


def value_returned(returned: String, value: String) -> Bool:
    """True when the trailer parser returned `value`.

    The parser returns one line per trailer it read, and a line may
    hold several comma-separated markers. The comparison is on the
    pieces, so `boxA#1, boxA#2` counts as returning both.
    """
    for line in returned.split("\n"):
        for piece in line.split(","):
            if String(piece.strip()) == value:
                return True
    return False


def contains_text(items: List[String], value: String) -> Bool:
    """True when `value` is already in `items`."""
    for i in range(len(items)):
        if items[i] == value:
            return True
    return False


def buried_trailer_values(body: String, returned: String) -> List[String]:
    """The values the body carries that the trailer parser did not see.

    Git's last-trailer-block rule returns the markers of the final
    block only. A body with two marker blocks — a squash that names one
    row and a later paragraph that names another — therefore loses the
    earlier one. Every value in the body the parser did not return is
    reported, so the scan names what it did not act on.
    """
    var buried = List[String]()
    var values = body_trailer_values(body)
    for i in range(len(values)):
        if value_returned(returned, values[i]):
            continue
        if contains_text(buried, values[i]):
            continue
        buried.append(values[i])
    return buried^


def scan_trailers(root: String, since: String) -> Scan:
    """Every trailer marker reachable from HEAD, newest commit first."""
    var scan = Scan()
    # The revision range the scan walks. It is named `span`, not
    # `range`: a local called `range` shadows the builtin the loop
    # below needs, and the compiler would call the string.
    var span = "HEAD"
    if since != "":
        span = since + "..HEAD"
    var format = (
        "--format=%H%x00%ct%x00%(trailers:key="
        + TRAILER_KEY
        + ",valueonly)%x00%B%x1e"
    )
    var args = "log " + shell_quote(format) + " " + shell_quote(span)
    var out = git_output(root, args)

    for raw in out.split(RECORD):
        var record = String(raw.strip())
        if record == "":
            continue
        var fields = record.split(FIELD)
        if len(fields) < 4:
            continue
        var commit = String(fields[0].strip())
        if commit == "":
            continue
        var epoch: Int
        try:
            epoch = Int(String(fields[1].strip()))
        except:
            continue
        var values = String(fields[2])
        var body = String(fields[3])

        # Every value the body carries that the trailer parser did not
        # return is buried — a later trailer block hid it. The scan
        # names it instead of letting it disappear.
        var buried = buried_trailer_values(body, values)
        for i in range(len(buried)):
            scan.hidden.append(
                first_nine(commit)
                + ": "
                + TRAILER_KEY
                + ": "
                + buried[i]
                + " is not in the commit's last trailer block"
                + " (a later block, e.g. Co-authored-by, hides it)"
                + " \u2014 resolve those rows by hand"
            )
        for value_line in values.split("\n"):
            for piece in value_line.split(","):
                var value = String(piece.strip())
                if value == "":
                    continue
                var parsed = parse_marker(value)
                if not parsed:
                    scan.malformed.append(sanitize(value))
                    continue
                var marker = parsed.take()
                add_marker(
                    scan.located, marker.machine, marker.id, commit, epoch
                )
    return scan^


struct ReportFile(Movable):
    """One report file a full or bounded scan will read, and its stamp."""

    var path: String
    var commit: String
    var epoch: Int

    def __init__(out self, path: String = "", commit: String = "", epoch: Int = 0):
        self.path = path
        self.commit = commit
        self.epoch = epoch


def latest_report_commit(
    root: String, relative: String, revision: String
) -> ReportFile:
    """The newest commit in `revision` that touched one report file."""
    var args = (
        "log -1 "
        + shell_quote("--format=%H%x00%ct")
        + " "
        + shell_quote(revision)
        + " -- "
        + shell_quote(relative)
    )
    var out = String(git_output(root, args).strip())
    if out == "":
        return ReportFile()
    var fields = out.split(FIELD)
    if len(fields) < 2:
        return ReportFile()
    var commit = String(fields[0].strip())
    var epoch: Int
    try:
        epoch = Int(String(fields[1].strip()))
    except:
        return ReportFile()
    if commit == "":
        return ReportFile()
    return ReportFile(relative, commit, epoch)


def contains_index(items: List[Int], value: Int) -> Bool:
    """True when `value` is in `items`."""
    for i in range(len(items)):
        if items[i] == value:
            return True
    return False


def newest_first(files: List[ReportFile]) -> List[ReportFile]:
    """The files by their stamp, newest first.

    Selection rather than a sort: Mojo 1.2's `List` has no ordering, and
    a scan reads a handful of reports, not a database.
    """
    var order = List[Int]()
    for _ in range(len(files)):
        var best = -1
        for i in range(len(files)):
            if contains_index(order, i):
                continue
            if best == -1 or files[i].epoch > files[best].epoch:
                best = i
        if best != -1:
            order.append(best)
    var sorted = List[ReportFile]()
    for i in range(len(order)):
        var file = ReportFile(
            files[order[i]].path,
            files[order[i]].commit,
            files[order[i]].epoch,
        )
        sorted.append(file^)
    return sorted^


def report_files(root: String, since: String) raises -> List[ReportFile]:
    """The report files a scan reads: the range's, or the tree's.

    A bounded scan asks git which reports the range added or modified; a
    full scan lists the directory. The tree is only read when the report
    directory exists — that is the mode switch `report` uses too.
    """
    var directory = root + "/" + REPORT_DIR
    if not Path(directory).is_dir():
        return List[ReportFile]()

    var files = List[ReportFile]()
    if since == "":
        for entry in Path(directory).listdir():
            var name = String(entry)
            if not name.endswith(".md"):
                continue
            var relative = REPORT_DIR + "/" + name
            if not Path(root + "/" + relative).is_file():
                continue
            var file = latest_report_commit(root, relative, "HEAD")
            if file.commit != "":
                files.append(file^)
        return newest_first(files)

    var args = (
        "diff --name-only --diff-filter=AM "
        + shell_quote(since + "..HEAD")
        + " -- "
        + shell_quote(REPORT_DIR)
    )
    var listing = git_output(root, args)
    var prefix = REPORT_DIR + "/"
    for line in listing.split("\n"):
        var relative = String(line.strip())
        if relative == "" or not relative.startswith(prefix):
            continue
        if not relative.endswith(".md"):
            continue
        var file = latest_report_commit(root, relative, since + "..HEAD")
        if file.commit != "":
            files.append(file^)
    return newest_first(files)


def scan_reports(root: String, since: String) raises -> Scan:
    """Markers from the report files this scan reads.

    The marker text is read from the commit that carries the file, not
    from the working tree: a hook runs after a merge, and the checkout
    may hold edits that are not part of the pull.
    """
    var scan = Scan()
    var files = report_files(root, since)
    for i in range(len(files)):
        var content = git_output(
            root,
            "show " + shell_quote(files[i].commit + ":" + files[i].path),
        )
        for line in content.split("\n"):
            var value = String(line.strip())
            if value == "":
                continue
            var parsed = parse_marker(value)
            if not parsed:
                scan.malformed.append(
                    sanitize(files[i].path + ": " + value)
                )
                continue
            var marker = parsed.take()
            add_marker(
                scan.located,
                marker.machine,
                marker.id,
                files[i].commit,
                files[i].epoch,
            )
    return scan^


# ---------------------------------------------------------------- answers


def skipped_json(items: List[MergedSkip]) -> String:
    """The skipped rows as an array of `{row, reason}` objects."""
    var out = "["
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += "{\"row\":" + json_string(items[i].row)
        out += ",\"reason\":" + json_string(items[i].reason) + "}"
    out += "]"
    return out


def ignored_markers(chosen: Scan, hidden: List[String]) -> List[String]:
    """Every marker the scan did not act on, hidden and malformed alike.

    SPEC §5.6 names one array for both: "hidden and malformed markers
    are reported with their ids or text in `ignored`, never silently
    dropped". A malformed value reaches the JSON only through this
    array, so a `--quiet --json` caller still learns about it — the
    quiet suppresses the stderr notes, not the report.

    The malformed text comes first: it is the value itself, where the
    hidden entry carries the commit it was buried in.
    """
    var items = List[String]()
    for i in range(len(chosen.malformed)):
        items.append(chosen.malformed[i])
    for i in range(len(hidden)):
        items.append(hidden[i])
    return items^


def stamped_markers(result: MergedResult) -> List[String]:
    """The markers of the rows a scan stamped, in order.

    The answer carries markers; the commit that stamped each one
    travels with it inside the result, for the writer and the summary.
    """
    var markers = List[String]()
    for i in range(len(result.stamped)):
        markers.append(result.stamped[i].marker)
    return markers^


def render_json(
    result: MergedResult, ignored: List[String], dry_run: Bool
) -> String:
    """One shape for every path, so a `--json` caller never guesses keys."""
    var out = "{\"resolved\":" + json_string_array(stamped_markers(result))
    out += ",\"unchanged\":" + json_string_array(result.unchanged)
    out += ",\"skipped\":" + skipped_json(result.skipped)
    out += ",\"ignored\":" + json_string_array(ignored)
    out += ",\"dry_run\":" + json_bool(dry_run)
    out += "}"
    return out


def first_nine(text: String) -> String:
    """The first nine bytes of a commit hash, or the whole short hash."""
    if text.byte_length() <= 9:
        return text
    return String(text[byte=0:9])


def unique_sorted(items: List[String]) -> List[String]:
    """`items` deduplicated and sorted."""
    var out = List[String]()
    for i in range(len(items)):
        var placed = False
        var rebuilt = List[String]()
        for j in range(len(out)):
            if not placed and items[i] < out[j]:
                rebuilt.append(items[i])
                placed = True
            if out[j] != items[i]:
                rebuilt.append(out[j])
        if not placed:
            rebuilt.append(items[i])
        out = rebuilt^
    return out^


def summary(result: MergedResult, dry_run: Bool) -> String:
    """The one stdout line a non-JSON scan prints when it stamped a row.

    Nothing to stamp means nothing to say: the hook's output has to stay
    trustworthy, so a pull with no markers is silent.

    The commit each row was stamped with travels with the marker in the
    result, so the summary names it without searching the scan for the
    marker that matches.
    """
    if len(result.stamped) == 0:
        return ""
    var commits = List[String]()
    for i in range(len(result.stamped)):
        commits.append(first_nine(result.stamped[i].commit))
    var shorts = unique_sorted(commits)
    var verb = "resolved"
    if dry_run:
        verb = "would resolve"
    var noun = " invocation"
    if len(result.stamped) != 1:
        noun += "s"
    return (
        verb
        + " "
        + String(len(result.stamped))
        + noun
        + " ("
        + ", ".join(shorts)
        + ")"
    )


def notes_for(
    hidden: List[String],
    chosen: Scan,
    stale_trailer: Bool,
    result: MergedResult,
    quiet: Bool,
) -> String:
    """The stderr notes, already prefixed, or nothing when quiet."""
    if quiet:
        return ""
    var lines = List[String]()
    for i in range(len(chosen.malformed)):
        lines.append(
            "not a "
            + TRAILER_KEY
            + " marker (machine#id): "
            + chosen.malformed[i]
        )
    for i in range(len(hidden)):
        lines.append("ignored marker \u2014 " + hidden[i])
    if stale_trailer:
        lines.append(
            "this repo resolves from "
            + REPORT_DIR
            + "; a "
            + TRAILER_KEY
            + " trailer is not read (run `skill-log report`)"
        )
    for i in range(len(result.skipped)):
        lines.append(
            result.skipped[i].row
            + " skipped: "
            + result.skipped[i].reason
        )
    return prefixed(lines)


def local_hostname() -> String:
    """This machine's hostname, or empty when it cannot be read.

    Only a row written before `add` always filled the column needs it.
    Its absence must not stop a hook from resolving the rows that do
    carry a machine.
    """
    try:
        return hostname()
    except:
        return ""


def handle_resolve_merged(args: List[String]) raises -> Outcome:
    """The `resolve-merged` handler.

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
            "resolve-merged runs inside a git checkout", EXIT_FAILURE()
        )

    # Bound the range only when git can resolve the revision. A missing
    # reflog entry is a hook's normal condition after a fresh clone, so
    # it falls back to a full scan quietly rather than failing a pull.
    var since = options.since
    if since != "":
        var commit = git_commit(root, since)
        if commit != "":
            since = commit
        else:
            since = ""

    var artifact = Path(root + "/" + REPORT_DIR).is_dir()
    var trailer_scan = scan_trailers(root, since)
    var hidden = trailer_scan.hidden.copy()
    var chosen: Scan
    var stale_trailer = False
    if artifact:
        chosen = scan_reports(root, since)
        # A trailer in a repo that resolves from files is stale, not
        # malformed: say it once, and read only the files.
        stale_trailer = len(trailer_scan.located) > 0
    else:
        chosen = trailer_scan^

    # The markers the scan did not act on: the malformed values it read
    # and the ones the trailer parse hid. Both are reported in one
    # array, so `--quiet --json` still says what was dropped.
    var ignored = ignored_markers(chosen, hidden)

    var result = MergedResult()
    if len(chosen.located) > 0:
        var path = resolve_db(options.db)
        if Path(path).is_file():
            try:
                result = resolve_merged_rows(
                    path, chosen.located, local_hostname(), options.dry_run
                )
            except e:
                var notes = notes_for(
                    hidden,
                    chosen,
                    stale_trailer,
                    result,
                    options.quiet,
                )
                # The store classifies the failure and raises its named
                # message (SPEC §3); this handler adds nothing to it.
                return Outcome.fail_notes(
                    String(e),
                    EXIT_FAILURE(),
                    notes,
                )
            if result.refusal.refused():
                var failure = result.refusal.failure()
                var notes = notes_for(
                    hidden,
                    chosen,
                    stale_trailer,
                    result,
                    options.quiet,
                )
                return Outcome.fail_notes(
                    failure.message, failure.code, notes
                )

    var notes = notes_for(
        hidden,
        chosen,
        stale_trailer,
        result,
        options.quiet,
    )

    if options.json:
        return Outcome.ok_notes(
            render_json(result, ignored, options.dry_run),
            notes,
        )
    return Outcome.ok_notes(summary(result, options.dry_run), notes)
