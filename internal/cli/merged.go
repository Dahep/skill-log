package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/process"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

// mergedOptions are the flags `resolve-merged` accepts.
type mergedOptions struct {
	since  string
	quiet  bool
	dryRun bool
	json   bool
	db     string
}

// resolveMergedVerb is the `resolve-merged` verb: close the rows a pull
// landed.
//
// `report` writes the markers into the change; this verb reads them back
// from the commits a pull brought in and stamps each named row with the
// commit that carries its fix. It is the post-merge hook's entry point, so
// it is bounded, quiet, and safe to run after every pull.
//
// The scan has two modes. A checkout that carries `.skill-log/reports/`
// resolves from the report files the range added or changed; a checkout
// without one resolves from the last trailer block of each commit. A
// marker the trailer parser hid — a multi-author squash puts
// `Co-authored-by:` in a later block — is reported with its value instead of
// being dropped, and so is a value that is not `machine#id`.
func resolveMergedVerb() Verb {
	return Verb{
		Name:    "resolve-merged",
		Summary: "stamp the rows a pull landed with the commits that fix them",
		Usage: "skill-log resolve-merged [--since <rev>] [--quiet] [--dry-run]\n" +
			"                            [--json] [--db <path>]",
		Examples: []string{
			"skill-log resolve-merged",
			"skill-log resolve-merged --since HEAD@{1} --quiet",
			"skill-log resolve-merged --since origin/main~5 --dry-run --json",
		},
		// The flags that consume the next argument. The dispatcher reads this
		// to tell `--since -h` (a revision spelled `-h`) from a help request.
		ValueFlags: []string{"--since", "--db"},
		Notes: "A checkout with .skill-log/reports/ resolves from the report files\n" +
			"the range added or changed; elsewhere the last trailer block of\n" +
			"each commit is the report. A later trailer block hides an\n" +
			"earlier marker, and that marker is reported, never dropped.\n" +
			"\n" +
			"--since bounds the scan to what a pull landed, which is what the\n" +
			"post-merge hook passes (the pre-merge reflog position). A range\n" +
			"git cannot resolve falls back to a quiet full scan.\n" +
			"\n" +
			"The newest marker for a row wins, a row logged after the named\n" +
			"commit is skipped with its reason, and a second scan stamps\n" +
			"nothing. A missing store is nothing to do, exit 0. --quiet\n" +
			"suppresses the notes; --dry-run writes nothing.",
		Handle: handleResolveMerged,
	}
}

func init() { register(resolveMergedVerb()) }

// parseMergedOptions reads `resolve-merged`'s flags.
//
// An unknown flag, a missing value or an option-shaped `--since` is a usage
// error, raised as a `usage` marker the caller turns into exit 2.
func parseMergedOptions(args []string) (mergedOptions, error) {
	var options mergedOptions
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--since":
			value, err := takeValue(args, i, "--since", "a revision")
			if err != nil {
				return options, err
			}
			options.since = value
			i++
		case strings.HasPrefix(arg, "--since="):
			options.since = strings.TrimPrefix(arg, "--since=")
		case arg == "--db":
			value, err := takeValue(args, i, "--db", "a path")
			if err != nil {
				return options, err
			}
			options.db = value
			i++
		case arg == "--quiet":
			options.quiet = true
		case arg == "--dry-run":
			options.dryRun = true
		case arg == "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + arg}
		}
	}

	since := strings.TrimSpace(options.since)
	if since != "" {
		// A revision reaches a git command and git's option parser. An
		// option-shaped value would be read as an option, so it is refused
		// before either sees it.
		if strings.HasPrefix(since, "-") || format.Sanitize(since) != since {
			return options, usageError{"--since needs a revision"}
		}
	}
	options.since = since
	return options, nil
}

// ---------------------------------------------------------------- scanning

// The field and record separators of one `git log` call.
//
// NUL cannot appear in a commit message or an object name, so it cannot be
// confused with data. The record separator ends one commit's fields: git
// commit bodies cannot carry it usefully and no marker does, so one call
// carries every commit's fields.
const (
	mergedField  = "\x00"
	mergedRecord = "\x1e"
)

// scan is what one pass over history found: markers, bad values, hidden ones.
//
// `located` is the scan's yield: one located marker per row the scan named.
type mergedScan struct {
	located   []store.Located
	malformed []string
	hidden    []string
}

// addLocated keeps the first marker for a row: newest wins, oldest is
// ignored.
//
// The scan walks commits newest first, so the first marker it meets is the
// newest commit that names the row.
func addLocated(located []store.Located, machine string, id int64, commit string, epoch int64) []store.Located {
	for _, item := range located {
		if item.Machine == machine && item.ID == id {
			return located
		}
	}
	return append(located, store.Located{
		Machine: machine, ID: id, Commit: commit, Epoch: epoch,
	})
}

// gitOutput runs one git command in dir and returns its exact stdout.
//
// The stderr is discarded so a range git cannot read is a quiet empty answer
// rather than noise on a pull. The arguments are passed as argv, never
// through a shell, so a path or a revision cannot reach git as an option.
func gitOutput(dir string, args ...string) string {
	result := process.Run(dir, "git", args...)
	if result.Status != 0 {
		return ""
	}
	return result.Stdout
}

// gitCommit is the commit `revision` names, or an empty string.
//
// This is the bound check: a reflog position that does not exist is not an
// error here, it is a missing bound, and the caller falls back to a full
// scan.
func gitCommit(root, revision string) string {
	out := gitOutput(root, "rev-parse", "--verify", revision+"^{commit}")
	return strings.TrimSpace(out)
}

// bodyTrailerValues is every marker the body's `Skill-log-Fix:` lines carry,
// in body order.
//
// The scan is line-based and prefix-based, like the marker grammar itself: a
// line whose first characters are the key, then a colon, then the value. A
// prose mention of the key in the middle of a paragraph is not a marker.
//
// A line may hold several comma-separated markers — the trailer grammar
// allows it — so the line's value is split into its pieces here. Both sides
// of the comparison are then one marker each, which is the only way "did the
// parser return this one?" has an answer.
func bodyTrailerValues(body string) []string {
	var values []string
	key := strings.ToLower(trailerKey)
	for _, line := range strings.Split(body, "\n") {
		text := strings.TrimSpace(line)
		lower := strings.ToLower(text)
		if !strings.HasPrefix(lower, key) {
			continue
		}
		rest := text[len(key):]
		trimmed := strings.TrimSpace(rest)
		if trimmed == "" || !strings.HasPrefix(trimmed, ":") {
			continue
		}
		value := strings.TrimSpace(trimmed[1:])
		if value == "" {
			continue
		}
		for _, piece := range strings.Split(value, ",") {
			one := strings.TrimSpace(piece)
			if one != "" {
				values = append(values, format.Sanitize(one))
			}
		}
	}
	return values
}

// valueReturned reports whether the trailer parser returned `value`.
//
// The parser returns one line per trailer it read, and a line may hold
// several comma-separated markers. The comparison is on the pieces, so
// `boxA#1, boxA#2` counts as returning both.
func valueReturned(returned, value string) bool {
	for _, line := range strings.Split(returned, "\n") {
		for _, piece := range strings.Split(line, ",") {
			if strings.TrimSpace(piece) == value {
				return true
			}
		}
	}
	return false
}

// containsText reports whether `value` is already in `items`.
func containsText(items []string, value string) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

// buriedTrailerValues is the values the body carries that the trailer parser
// did not see.
//
// Git's last-trailer-block rule returns the markers of the final block only.
// A body with two marker blocks — a squash that names one row and a later
// paragraph that names another — therefore loses the earlier one. Every value
// in the body the parser did not return is reported, so the scan names what
// it did not act on.
func buriedTrailerValues(body, returned string) []string {
	var buried []string
	for _, value := range bodyTrailerValues(body) {
		if valueReturned(returned, value) {
			continue
		}
		if containsText(buried, value) {
			continue
		}
		buried = append(buried, value)
	}
	return buried
}

// scanTrailers is every trailer marker reachable from HEAD, newest commit
// first.
func scanTrailers(root, since string) mergedScan {
	var scan mergedScan
	// The revision range the scan walks.
	span := "HEAD"
	if since != "" {
		span = since + "..HEAD"
	}
	logFormat := "--format=%H%x00%ct%x00%(trailers:key=" +
		trailerKey + ",valueonly)%x00%B%x1e"
	out := gitOutput(root, "log", logFormat, span)

	for _, raw := range strings.Split(out, mergedRecord) {
		record := strings.TrimSpace(raw)
		if record == "" {
			continue
		}
		fields := strings.Split(record, mergedField)
		if len(fields) < 4 {
			continue
		}
		commit := strings.TrimSpace(fields[0])
		if commit == "" {
			continue
		}
		epoch, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			continue
		}
		values := fields[2]
		body := fields[3]

		// Every value the body carries that the trailer parser did not
		// return is buried — a later trailer block hid it. The scan names it
		// instead of letting it disappear.
		for _, value := range buriedTrailerValues(body, values) {
			scan.hidden = append(scan.hidden,
				firstNine(commit)+
					": "+trailerKey+": "+value+
					" is not in the commit's last trailer block"+
					" (a later block, e.g. Co-authored-by, hides it)"+
					" — resolve those rows by hand")
		}
		for _, valueLine := range strings.Split(values, "\n") {
			for _, piece := range strings.Split(valueLine, ",") {
				value := strings.TrimSpace(piece)
				if value == "" {
					continue
				}
				parsed, ok := marker.Parse(value)
				if !ok {
					scan.malformed = append(scan.malformed, format.Sanitize(value))
					continue
				}
				scan.located = addLocated(
					scan.located, parsed.Machine, parsed.ID, commit, epoch,
				)
			}
		}
	}
	return scan
}

// reportFile is one report file a full or bounded scan will read, and its
// stamp.
type reportFile struct {
	path   string
	commit string
	epoch  int64
}

// latestReportCommit is the newest commit in `revision` that touched one
// report file.
func latestReportCommit(root, relative, revision string) reportFile {
	out := strings.TrimSpace(gitOutput(
		root, "log", "-1", "--format=%H%x00%ct", revision, "--", relative,
	))
	if out == "" {
		return reportFile{}
	}
	fields := strings.Split(out, mergedField)
	if len(fields) < 2 {
		return reportFile{}
	}
	commit := strings.TrimSpace(fields[0])
	epoch, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
	if err != nil {
		return reportFile{}
	}
	if commit == "" {
		return reportFile{}
	}
	return reportFile{path: relative, commit: commit, epoch: epoch}
}

// newestFirst is the files by their stamp, newest first.
//
// Selection rather than a sort: the scan reads a handful of reports, not a
// database.
func newestFirst(files []reportFile) []reportFile {
	order := make([]int, 0, len(files))
	taken := make([]bool, len(files))
	for range files {
		best := -1
		for i, file := range files {
			if taken[i] {
				continue
			}
			if best == -1 || file.epoch > files[best].epoch {
				best = i
			}
		}
		if best != -1 {
			taken[best] = true
			order = append(order, best)
		}
	}
	sorted := make([]reportFile, 0, len(order))
	for _, index := range order {
		sorted = append(sorted, files[index])
	}
	return sorted
}

// reportFiles is the report files a scan reads: the range's, or the tree's.
//
// A bounded scan asks git which reports the range added or modified; a full
// scan lists the directory. The tree is only read when the report directory
// exists — that is the mode switch `report` uses too.
func reportFiles(root, since string) []reportFile {
	directory := filepath.Join(root, filepath.FromSlash(reportDir))
	if !format.IsDir(directory) {
		return nil
	}

	var files []reportFile
	if since == "" {
		entries, err := os.ReadDir(directory)
		if err != nil {
			return nil
		}
		for _, entry := range entries {
			name := entry.Name()
			if !strings.HasSuffix(name, ".md") {
				continue
			}
			relative := reportDir + "/" + name
			if !format.IsRegularFile(filepath.Join(root, filepath.FromSlash(relative))) {
				continue
			}
			file := latestReportCommit(root, relative, "HEAD")
			if file.commit != "" {
				files = append(files, file)
			}
		}
		return newestFirst(files)
	}

	listing := gitOutput(
		root, "diff", "--name-only", "--diff-filter=AM",
		since+"..HEAD", "--", reportDir,
	)
	prefix := reportDir + "/"
	for _, line := range strings.Split(listing, "\n") {
		relative := strings.TrimSpace(line)
		if relative == "" || !strings.HasPrefix(relative, prefix) {
			continue
		}
		if !strings.HasSuffix(relative, ".md") {
			continue
		}
		file := latestReportCommit(root, relative, since+"..HEAD")
		if file.commit != "" {
			files = append(files, file)
		}
	}
	return newestFirst(files)
}

// scanReports is the markers from the report files this scan reads.
//
// The marker text is read from the commit that carries the file, not from
// the working tree: a hook runs after a merge, and the checkout may hold
// edits that are not part of the pull.
func scanReports(root, since string) mergedScan {
	var scan mergedScan
	for _, file := range reportFiles(root, since) {
		content := gitOutput(root, "show", file.commit+":"+file.path)
		for _, line := range strings.Split(content, "\n") {
			value := strings.TrimSpace(line)
			if value == "" {
				continue
			}
			parsed, ok := marker.Parse(value)
			if !ok {
				scan.malformed = append(scan.malformed,
					format.Sanitize(file.path+": "+value))
				continue
			}
			scan.located = addLocated(
				scan.located, parsed.Machine, parsed.ID, file.commit, file.epoch,
			)
		}
	}
	return scan
}

// ---------------------------------------------------------------- answers

// skippedJSON is the skipped rows as an array of `{row, reason}` objects.
func skippedJSON(items []store.MergedSkip) string {
	var out strings.Builder
	out.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(`{"row":`)
		out.WriteString(format.JSONString(item.Row))
		out.WriteString(`,"reason":`)
		out.WriteString(format.JSONString(item.Reason))
		out.WriteByte('}')
	}
	out.WriteByte(']')
	return out.String()
}

// ignoredMarkers is every marker the scan did not act on, hidden and
// malformed alike.
//
// SPEC §5.6 names one array for both: "hidden and malformed markers are
// reported with their ids or text in `ignored`, never silently dropped". A
// malformed value reaches the JSON only through this array, so a
// `--quiet --json` caller still learns about it — the quiet suppresses the
// stderr notes, not the report.
//
// The malformed text comes first: it is the value itself, where the hidden
// entry carries the commit it was buried in.
func ignoredMarkers(outcome mergedOutcome) []string {
	items := make([]string, 0,
		len(outcome.scan.malformed)+len(outcome.hidden))
	items = append(items, outcome.scan.malformed...)
	items = append(items, outcome.hidden...)
	return items
}

// stampedMarkers is the markers of the rows a scan stamped, in order.
//
// The answer carries markers; the commit that stamped each one travels with
// it inside the result, for the writer and the summary.
func stampedMarkers(result store.MergedResult) []string {
	markers := make([]string, 0, len(result.Stamped))
	for _, item := range result.Stamped {
		markers = append(markers, item.Marker)
	}
	return markers
}

// renderMergedJSON is one shape for every path, so a `--json` caller never
// guesses keys.
func renderMergedJSON(result store.MergedResult, ignored []string, dryRun bool) string {
	var out strings.Builder
	out.WriteString(`{"resolved":`)
	out.WriteString(format.JSONStrings(stampedMarkers(result)))
	out.WriteString(`,"unchanged":`)
	out.WriteString(format.JSONStrings(result.Unchanged))
	out.WriteString(`,"skipped":`)
	out.WriteString(skippedJSON(result.Skipped))
	out.WriteString(`,"ignored":`)
	out.WriteString(format.JSONStrings(ignored))
	out.WriteString(`,"dry_run":`)
	out.WriteString(format.JSONBool(dryRun))
	out.WriteByte('}')
	return out.String()
}

// mergedSummary is the one stdout line a non-JSON scan prints when it
// stamped a row.
//
// Nothing to stamp means nothing to say: the hook's output has to stay
// trustworthy, so a pull with no markers is silent.
//
// The commit each row was stamped with travels with the marker in the
// result, so the summary names it without searching the scan for the marker
// that matches.
func mergedSummary(result store.MergedResult, dryRun bool) string {
	if len(result.Stamped) == 0 {
		return ""
	}
	commits := make([]string, 0, len(result.Stamped))
	for _, item := range result.Stamped {
		commits = append(commits, firstNine(item.Commit))
	}
	shorts := sortedUnique(commits)
	verb := "resolved"
	if dryRun {
		verb = "would resolve"
	}
	noun := " invocation"
	if len(result.Stamped) != 1 {
		noun += "s"
	}
	return verb + " " + formatInt(int64(len(result.Stamped))) + noun +
		" (" + strings.Join(shorts, ", ") + ")"
}

// mergedOutcome is what one scan decided and what it wants to say about it.
//
// The three scan-derived facts travel together because the notes, the
// ignored array and the summary all read the same scan: the markers it
// found, the markers it could not use, and the trailer it ignored.
type mergedOutcome struct {
	// scan is the scan whose markers were acted on: the report files in
	// artifact mode, the trailers otherwise.
	scan mergedScan
	// hidden is the markers the trailer parse buried, whatever mode the
	// scan ran in.
	hidden []string
	// staleTrailer says a trailer was found in a checkout that resolves
	// from its report files.
	staleTrailer bool
}

// mergedNotes is the stderr notes, already prefixed, or nothing when quiet.
func mergedNotes(outcome mergedOutcome, result store.MergedResult, quiet bool) string {
	if quiet {
		return ""
	}
	var lines []string
	for _, value := range outcome.scan.malformed {
		lines = append(lines,
			"not a "+trailerKey+" marker (machine#id): "+value)
	}
	for _, value := range outcome.hidden {
		lines = append(lines, "ignored marker — "+value)
	}
	if outcome.staleTrailer {
		lines = append(lines,
			"this repo resolves from "+reportDir+
				"; a "+trailerKey+" trailer is not read (run `skill-log report`)")
	}
	for _, item := range result.Skipped {
		lines = append(lines, item.Row+" skipped: "+item.Reason)
	}
	return format.Prefixed(lines)
}

// localHostname is this machine's hostname, or empty when it cannot be read.
//
// Only a row written before `add` always filled the column needs it. Its
// absence must not stop a hook from resolving the rows that do carry a
// machine.
func localHostname() string {
	name, err := settings.Hostname()
	if err != nil {
		return ""
	}
	return name
}

func handleResolveMerged(args []string) Outcome {
	options, err := parseMergedOptions(args)
	if err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
	}

	root := settings.GitToplevel()
	if root == "" {
		return Fail(
			"resolve-merged runs inside a git checkout", ExitFailure,
		)
	}

	// Bound the range only when git can resolve the revision. A missing
	// reflog entry is a hook's normal condition after a fresh clone, so it
	// falls back to a full scan quietly rather than failing a pull.
	since := options.since
	if since != "" {
		commit := gitCommit(root, since)
		if commit != "" {
			since = commit
		} else {
			since = ""
		}
	}

	artifact := format.IsDir(filepath.Join(root, filepath.FromSlash(reportDir)))
	trailerScan := scanTrailers(root, since)
	var outcome mergedOutcome
	outcome.hidden = trailerScan.hidden
	if artifact {
		outcome.scan = scanReports(root, since)
		// A trailer in a repo that resolves from files is stale, not
		// malformed: say it once, and read only the files.
		outcome.staleTrailer = len(trailerScan.located) > 0
	} else {
		outcome.scan = trailerScan
	}

	// The markers the scan did not act on: the malformed values it read and
	// the ones the trailer parse hid. Both are reported in one array, so
	// `--quiet --json` still says what was dropped.
	ignored := ignoredMarkers(outcome)

	var result store.MergedResult
	if len(outcome.scan.located) > 0 {
		path := settings.ResolveDB(options.db)
		// The optional policy: an absent store is nothing to do, exit 0.
		opened, _, failure := openStore(path, store.PolicyOptional, "")
		if failure != nil {
			notes := mergedNotes(outcome, result, options.quiet)
			return FailNotes(failure.Message, failure.Code, notes)
		}
		if opened != nil {
			opened.Close()
			resolved, refusal, err := store.ResolveMergedRows(
				path, outcome.scan.located, localHostname(), options.dryRun,
			)
			if failure := writeOutcome(path, refusal, err); failure != nil {
				notes := mergedNotes(outcome, result, options.quiet)
				return FailNotes(failure.Message, failure.Code, notes)
			}
			result = resolved
		}
	}

	notes := mergedNotes(outcome, result, options.quiet)

	if options.json {
		return OKNotes(
			renderMergedJSON(result, ignored, options.dryRun), notes,
		)
	}
	return OKNotes(mergedSummary(result, options.dryRun), notes)
}
