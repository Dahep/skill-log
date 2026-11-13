"""The `resolve-merged` verb: close the rows a pull landed."""

from std.pathlib import Path

from skill_log.context import hostname
from skill_log.detect import shell_quote
from skill_log.errors import EXIT_FAILURE, EXIT_USAGE, Outcome
from skill_log.flags import take_declared_value
from skill_log.git import git, git_commit, git_toplevel
from skill_log.json import JsonObject
from skill_log.markers import parse_marker
from skill_log.report import REPORT_DIR, TRAILER_KEY
from skill_log.store import (
    resolve_merged_rows,
    MergedResult,
    MergedSkip,
    Located,
)
from skill_log.settings import resolve_db
from skill_log.text import prefixed, sanitize

# The record framing: NUL cannot appear in a commit message, so it cannot be
# confused with data.
comptime FIELD = "\u0000"


def resolve_merged_usage() -> String:
    return "skill-log resolve-merged [--since <rev>] [--quiet] [--dry-run]\n" \
           "                            [--json] [--db <path>]"


def resolve_merged_examples() -> List[String]:
    var examples = List[String]()
    examples.append("skill-log resolve-merged")
    examples.append("skill-log resolve-merged --since HEAD@{1} --quiet")
    examples.append("skill-log resolve-merged --since origin/main~5 --dry-run --json")
    return examples^


def resolve_merged_value_flags() -> List[String]:
    var flags = List[String]()
    flags.append("--since")
    flags.append("--db")
    return flags^


def resolve_merged_notes() -> String:
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
    """Read `resolve-merged`'s flags."""
    var options = Options()
    var value_flags = resolve_merged_value_flags()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--since":
            options.since = take_declared_value(
                args, i, "--since", "a revision", value_flags
            )
            i += 1
        elif arg.startswith("--since="):
            options.since = String(arg[byte=8:])
        elif arg == "--db":
            options.db = take_declared_value(
                args, i, "--db", "a path", value_flags
            )
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
        if since.startswith("-") or sanitize(since) != since:
            raise Error("usage: --since needs a revision")
    options.since = since^
    return options^




struct Scan(Movable):
    """What one pass over history found: markers, bad values, hidden ones."""

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
    """Keep the first marker for a row: newest wins, oldest is ignored."""
    if contains_pair(located, machine, id):
        return
    var marker = Located(machine, id, commit, epoch)
    located.append(marker^)


def body_trailer_values(body: String) -> List[String]:
    """Every marker the body's `Skill-log-Fix:` lines carry, in body order.

    The scan is line-based and prefix-based, like the marker grammar itself.
    A line may hold several comma-separated markers, so the line's value is
    split into its pieces here.
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
    """True when the trailer parser returned `value`."""
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

    Git's last-trailer-block rule returns the markers of the final block
    only, so a body with two marker blocks loses the earlier one. Every
    value the parser did not return is reported, not dropped.
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
    var span = "HEAD"
    if since != "":
        span = since + "..HEAD"
    var format = (
        "--format=%H%x00%ct%x00%(trailers:key="
        + TRAILER_KEY
        + ",valueonly)%x00%B%x00"
    )
    var args = "log " + shell_quote(format) + " " + shell_quote(span)
    var out = git(root, args)

    var fields = out.split(FIELD)
    var at = 0
    while at + 4 <= len(fields):
        var commit = String(fields[at].strip())
        if commit == "":
            at += 4
            continue
        var epoch: Int
        try:
            epoch = Int(String(fields[at + 1].strip()))
        except:
            at += 4
            continue
        var values = String(fields[at + 2])
        var body = String(fields[at + 3])
        at += 4

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
    var out = String(git(root, args).strip())
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
    """The files by their stamp, newest first."""
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
    """The report files a scan reads: the range's, or the tree's."""
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
    var listing = git(root, args)
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
    """Markers from the report files this scan reads."""
    var scan = Scan()
    var files = report_files(root, since)
    for i in range(len(files)):
        var content = git(
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




def skipped_json(items: List[MergedSkip]) -> String:
    """The skipped rows as an array of `{row, reason}` objects."""
    var out = "["
    for i in range(len(items)):
        if i > 0:
            out += ","
        var item = JsonObject()
        item.put("row", items[i].row)
        item.put("reason", items[i].reason)
        out += item.render()
    out += "]"
    return out


def ignored_markers(chosen: Scan, hidden: List[String]) -> List[String]:
    """Every marker the scan did not act on, hidden and malformed alike."""
    var items = List[String]()
    for i in range(len(chosen.malformed)):
        items.append(chosen.malformed[i])
    for i in range(len(hidden)):
        items.append(hidden[i])
    return items^


def stamped_markers(result: MergedResult) -> List[String]:
    """The markers of the rows a scan stamped, in order."""
    var markers = List[String]()
    for i in range(len(result.stamped)):
        markers.append(result.stamped[i].marker)
    return markers^


def render_json(
    result: MergedResult, ignored: List[String], dry_run: Bool
) -> String:
    """One shape for every path, so a `--json` caller never guesses keys."""
    var out = JsonObject()
    out.put_strings("resolved", stamped_markers(result))
    out.put_strings("unchanged", result.unchanged)
    out.put_raw("skipped", skipped_json(result.skipped))
    out.put_strings("ignored", ignored)
    out.put_bool("dry_run", dry_run)
    return out.render()


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
    """The one stdout line a non-JSON scan prints when it stamped a row."""
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
    """This machine's hostname, or empty when it cannot be read."""
    try:
        return hostname()
    except:
        return ""


def handle_resolve_merged(args: List[String]) raises -> Outcome:
    """The `resolve-merged` handler."""
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
            "resolve-merged runs inside a git checkout", EXIT_FAILURE()
        )

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
        stale_trailer = len(trailer_scan.located) > 0
    else:
        chosen = trailer_scan^

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
