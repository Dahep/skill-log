package cli

import (
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
		// The flags that consume the next argument: the dispatcher reads this
		// to tell `--since -h` from a help request.
		ValueFlags: mergedFlags(&mergedOptions{}).names(),
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

// mergedFlags reads `resolve-merged`'s flags.
func mergedFlags(options *mergedOptions) *flagSet {
	flags := &flagSet{}
	flags.valueEquals("--since", "a revision", func(value string) error { options.since = value; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	return flags
}

func parseMergedOptions(args []string) (mergedOptions, error) {
	var options mergedOptions
	flags := mergedFlags(&options)
	flags.switchFlag("--quiet", func() error { options.quiet = true; return nil })
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
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

// The field and record separators of one `git log` call.
//
// NUL cannot appear in a commit message or an object name, and the record
// separator ends one commit's fields, so one call carries every commit's.
const (
	mergedField  = "\x00"
	mergedRecord = "\x1e"
)

// mergedScan is what one pass over history found: markers, bad values,
// hidden ones.
type mergedScan struct {
	located   []store.Located
	malformed []string
	hidden    []string
}

// addLocated keeps the first marker for a row: the scan walks commits newest
// first, so the first marker it meets is the newest commit that names the row.
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
// rather than noise on a pull. The arguments go as argv, never through a
// shell, so a path or a revision cannot reach git as an option.
func gitOutput(dir string, args ...string) string {
	result := process.Run(dir, "git", args...)
	if result.Status != 0 {
		return ""
	}
	return result.Stdout
}

// gitCommit is the commit `revision` names, or an empty string: a reflog
// position that does not exist is a missing bound, not an error.
func gitCommit(root, revision string) string {
	out := gitOutput(root, "rev-parse", "--verify", revision+"^{commit}")
	return strings.TrimSpace(out)
}

// splitMarkerValues is the markers in one trailer value: the trailer grammar
// lets a line hold several, comma-separated.
func splitMarkerValues(value string) []string {
	var pieces []string
	for _, piece := range strings.Split(value, ",") {
		one := strings.TrimSpace(piece)
		if one != "" {
			pieces = append(pieces, one)
		}
	}
	return pieces
}

// bodyTrailerValues is every marker the body's `Skill-log-Fix:` lines carry,
// in body order.
//
// The scan is line-based and prefix-based, like the marker grammar itself: a
// line whose first characters are the key, then a colon, then the value. A
// prose mention of the key mid-paragraph is not a marker.
func bodyTrailerValues(body string) []string {
	var values []string
	key := strings.ToLower(trailerKey)
	for _, line := range strings.Split(body, "\n") {
		text := strings.TrimSpace(line)
		if !strings.HasPrefix(strings.ToLower(text), key) {
			continue
		}
		trimmed := strings.TrimSpace(text[len(key):])
		if trimmed == "" || !strings.HasPrefix(trimmed, ":") {
			continue
		}
		for _, piece := range splitMarkerValues(strings.TrimSpace(trimmed[1:])) {
			values = append(values, format.Sanitize(piece))
		}
	}
	return values
}

// valueReturned reports whether the trailer parser returned `value`. The
// parser returns one line per trailer it read, and a line may hold several
// comma-separated markers, so the comparison is on the pieces.
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
// Git's last-trailer-block rule returns the markers of the final block only,
// so a body with two marker blocks loses the earlier one. Every value the
// parser did not return is reported, so the scan names what it skipped.
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

		// A value the trailer parser did not return is buried — a later
		// trailer block hid it. The scan names it instead of losing it.
		for _, value := range buriedTrailerValues(body, values) {
			scan.hidden = append(scan.hidden,
				firstNine(commit)+
					": "+trailerKey+": "+value+
					" is not in the commit's last trailer block"+
					" (a later block, e.g. Co-authored-by, hides it)"+
					" — resolve those rows by hand")
		}
		for _, valueLine := range strings.Split(values, "\n") {
			for _, value := range splitMarkerValues(valueLine) {
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

// reportFile is one report file a scan reads, and its stamp.
type reportFile struct {
	path   string
	commit string
	epoch  int64
	order  int
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
func newestFirst(files []reportFile) []reportFile {
	order := make([]int, 0, len(files))
	taken := make([]bool, len(files))
	for range files {
		best := -1
		for i, file := range files {
			if taken[i] {
				continue
			}
			if best == -1 || file.epoch > files[best].epoch ||
				(file.epoch == files[best].epoch && file.order < files[best].order) {
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
// The tree is only read when the report directory exists — that is the mode
// switch `report` uses too.
func reportFiles(root, since string) []reportFile {
	directory := filepath.Join(root, filepath.FromSlash(reportDir))
	if !format.IsDir(directory) {
		return nil
	}

	span := "HEAD"
	if since != "" {
		span = since + "..HEAD"
	}
	// The committed tree at the scanned tip is the inventory. Working-tree
	// presence cannot hide or add a report from the pull.
	listing := gitOutput(root, "ls-tree", "-r", "--name-only", "HEAD", "--", reportDir)
	prefix := reportDir + "/"
	history := commitHistory(root, span)
	var files []reportFile
	for _, line := range strings.Split(listing, "\n") {
		relative := strings.TrimSpace(line)
		if relative == "" || !strings.HasPrefix(relative, prefix) {
			continue
		}
		name := strings.TrimPrefix(relative, prefix)
		if name == "README.md" || name == ".gitkeep" {
			continue
		}
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		file := latestReportCommit(root, relative, span)
		if file.commit != "" {
			file.order = history[file.commit]
			files = append(files, file)
		}
	}
	return newestFirst(files)
}

// commitHistory maps each commit in span to its newest-first history position.
func commitHistory(root, span string) map[string]int {
	out := gitOutput(root, "log", "--format=%H", span)
	history := make(map[string]int)
	for i, line := range strings.Split(out, "\n") {
		commit := strings.TrimSpace(line)
		if commit != "" {
			history[commit] = i
		}
	}
	return history
}

// scanReports is the markers from the report files this scan reads.
//
// The marker text is read from the commit that carries the file, not the
// working tree: a hook runs after a merge, and the checkout may hold edits
// that are not part of the pull.
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

// skippedJSON is the skipped rows as an array of `{row, reason}` objects.
func skippedJSON(items []store.MergedSkip) string {
	values := make([]string, 0, len(items))
	for _, item := range items {
		values = append(values, format.Object(
			format.Str("row", item.Row),
			format.Str("reason", item.Reason),
		))
	}
	return "[" + strings.Join(values, ",") + "]"
}

// ignoredMarkers is every marker the scan did not act on, hidden and
// malformed alike. The malformed text comes first: it is the value itself,
// where the hidden entry carries the commit it was buried in.
func ignoredMarkers(outcome mergedOutcome) []string {
	items := make([]string, 0,
		len(outcome.scan.malformed)+len(outcome.hidden))
	items = append(items, outcome.scan.malformed...)
	items = append(items, outcome.hidden...)
	return items
}

// stampedMarkers is the markers of the rows a scan stamped, in order.
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
	return format.Object(
		format.Raw("resolved", format.JSONStrings(stampedMarkers(result))),
		format.Raw("unchanged", format.JSONStrings(result.Unchanged)),
		format.Raw("skipped", skippedJSON(result.Skipped)),
		format.Raw("ignored", format.JSONStrings(ignored)),
		format.Bool("dry_run", dryRun),
	)
}

// mergedSummary is the one stdout line a non-JSON scan prints when it
// stamped a row. Nothing to stamp means nothing to say: the hook's output
// has to stay trustworthy, so a pull with no markers is silent.
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
	return prefixedNotes(lines)
}

// localHostname is this machine's hostname, or empty when it cannot be read.
// Only a row written before `add` always filled the column needs it, and its
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
		return usageOutcome(err)
	}

	root := settings.GitToplevel()
	if root == "" {
		return Fail(
			"resolve-merged runs inside a git checkout", ExitFailure,
		)
	}

	// Bound the range only when git can resolve the revision. A missing
	// reflog entry is a hook's normal condition after a fresh clone, so it
	// falls back to a full scan rather than failing a pull.
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

	// The markers the scan did not act on, in one array, so `--quiet --json`
	// still says what was dropped.
	ignored := ignoredMarkers(outcome)

	var result store.MergedResult
	if len(outcome.scan.located) > 0 {
		path := settings.ResolveDB(options.db)
		// The optional policy: an absent store is nothing to do, exit 0.
		opened, failure := openStore(path, false)
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
