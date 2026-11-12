package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

// The report directory, relative to the checkout's root. Its presence is
// what puts a checkout in artifact mode; its absence is trailer mode.
const reportDir = ".skill-log/reports"

// The commit-body trailer a checkout without the report directory uses.
const trailerKey = "Skill-log-Fix"

// The longest file-name slug. A branch name can be long; a report name
// does not need to be.
const maxSlug = 80

type reportOptions struct {
	ids        []int64
	run        string
	skill      string
	slug       string
	check      bool
	dryRun     bool
	json       bool
	db         string
	givenRun   bool
	givenSkill bool
	givenSlug  bool
}

func reportVerb() Verb {
	return Verb{
		Name:    "report",
		Summary: "name the rows a change fixes, in the report the change commits",
		Usage: "skill-log report (--id <n>... | --run <id> | --skill <name>)\n" +
			"                     [--slug <name>] [--check] [--dry-run]\n" +
			"                     [--json] [--db <path>]",
		Examples: []string{
			"skill-log report --id 42",
			"skill-log report --run ses_abc123",
			"skill-log report --skill create-skill --slug skill-fix",
			"skill-log report --check",
		},
		// The flags that consume the next argument. The dispatcher reads this
		// to tell `--run -h` (a run spelled `-h`) from a help request.
		ValueFlags: []string{"--id", "--run", "--skill", "--slug", "--db"},
		Notes: "The report is the transport: .skill-log/reports/<branch>.md,\n" +
			"one machine#id per line, committed with the change. Markers are\n" +
			"unioned with what the file already holds, and never carry problem\n" +
			"text or project details.\n" +
			"\n" +
			"A checkout without .skill-log/reports/ writes nothing: report\n" +
			"prints the Skill-log-Fix trailer to put in the commit body.\n" +
			"\n" +
			"Ids are validated here, at authoring time: an id this store does\n" +
			"not have is refused, and an already-resolved row is skipped and\n" +
			"named. --check validates the branch's report without writing;\n" +
			"--dry-run previews the write.",
		Handle: handleReport,
	}
}

func init() { register(reportVerb()) }

func parseReportOptions(args []string) (reportOptions, error) {
	var options reportOptions
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--id", "--run", "--skill", "--slug", "--db":
			what := map[string]string{
				"--id": "an id", "--run": "an id", "--skill": "a name",
				"--slug": "a name", "--db": "a path",
			}[arg]
			value, err := takeValue(args, i, arg, what)
			if err != nil {
				return options, err
			}
			switch arg {
			case "--id":
				id, err := parsePositive(value, "--id takes a positive integer")
				if err != nil {
					return options, err
				}
				options.ids = append(options.ids, id)
			case "--run":
				options.run = value
				options.givenRun = true
			case "--skill":
				options.skill = value
				options.givenSkill = true
			case "--slug":
				options.slug = value
				options.givenSlug = true
			case "--db":
				options.db = value
			}
			i++
		case "--check":
			options.check = true
		case "--dry-run":
			options.dryRun = true
		case "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + arg}
		}
	}
	if options.givenRun && strings.TrimSpace(options.run) == "" {
		return options, usageError{"--run needs an id"}
	}
	if options.givenSkill && strings.TrimSpace(options.skill) == "" {
		return options, usageError{"--skill needs a name"}
	}
	if options.givenSlug && strings.TrimSpace(options.slug) == "" {
		return options, usageError{"--slug needs a name"}
	}
	options.run = strings.TrimSpace(options.run)
	options.skill = strings.TrimSpace(options.skill)
	options.slug = strings.TrimSpace(options.slug)

	if !options.check && len(options.ids) == 0 &&
		options.run == "" && options.skill == "" {
		return options, usageError{
			"report needs --id, --run or --skill (or --check);" +
				" for example: skill-log report --run ses_abc123",
		}
	}
	return options, nil
}

// branchSlug is the report file's name for a branch: lowercase, safe,
// truncated.
//
// A branch name may carry `/`, spaces or unicode; a file name may not
// usefully. Every run of characters outside `[a-z0-9._-]` becomes one
// `-`, leading and trailing `.`/`-` are dropped, and the result is cut
// to maxSlug. The same rule the reference used, so an existing report
// keeps its name after the port.
func branchSlug(branch string) string {
	lower := strings.ToLower(strings.TrimSpace(branch))
	var out strings.Builder
	pendingDash := false
	for _, c := range lower {
		keep := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-'
		if keep {
			if pendingDash && out.Len() > 0 {
				out.WriteByte('-')
			}
			out.WriteRune(c)
			pendingDash = false
			continue
		}
		pendingDash = true
	}
	trimmed := trimSlug(out.String())
	if len(trimmed) > maxSlug {
		return trimmed[:maxSlug]
	}
	return trimmed
}

// trimSlug is text without leading or trailing `.` and `-`.
func trimSlug(text string) string {
	start := 0
	stop := len(text)
	for start < stop && (text[start] == '-' || text[start] == '.') {
		start++
	}
	for stop > start && (text[stop-1] == '-' || text[stop-1] == '.') {
		stop--
	}
	return text[start:stop]
}

// containsInt reports whether value is in items.
func containsInt(items []int64, value int64) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

// addSorted is items plus value, sorted and without a duplicate.
//
// Insertion rather than a sort: these lists are tiny (one marker per
// resolved row).
func addSorted(items []string, value string) []string {
	out := make([]string, 0, len(items)+1)
	placed := false
	for _, item := range items {
		if !placed && value < item {
			out = append(out, value)
			placed = true
		}
		if item != value {
			out = append(out, item)
		}
	}
	if !placed {
		out = append(out, value)
	}
	return out
}

// sortedUnique is items deduplicated and sorted.
func sortedUnique(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = addSorted(out, item)
	}
	return out
}

// joinInts is the ids, comma-separated, for one diagnostic line.
func joinInts(items []int64) string {
	parts := make([]string, 0, len(items))
	for _, item := range items {
		parts = append(parts, formatInt(item))
	}
	return strings.Join(parts, ", ")
}

// problemsLine is the one failure line for a report with count bad lines.
func problemsLine(count int) string {
	if count == 1 {
		return "report check failed: 1 line is not a marker"
	}
	return "report check failed: " + formatInt(int64(count)) + " lines are not markers"
}

// markerCount is `1 marker` or `N markers`.
func markerCount(count int) string {
	if count == 1 {
		return "1 marker"
	}
	return formatInt(int64(count)) + " markers"
}

// firstNine is the first nine bytes of a commit hash, or the whole short
// hash.
func firstNine(text string) string {
	if len(text) <= 9 {
		return text
	}
	return text[:9]
}

// reportSelection is what the selectors found: markers to write, rows
// already closed, and ids the store does not have.
//
// `missing` is a failure, not an empty selection: a caller who named an
// id expects that row in the report, and silently writing four of five
// markers is worse than refusing.
type reportSelection struct {
	pending  []string
	resolved []string
	missing  []int64
}

// recordReportRow sorts one row into the report (pending) or the skip
// list (resolved).
func recordReportRow(row store.Invocation, pending, resolved *[]string) {
	text := marker.Format(row.Machine, row.ID)
	if row.Fix != "" {
		*resolved = append(*resolved, text)
		return
	}
	*pending = append(*pending, text)
}

// selectReportMarkers is the markers the selectors name, split into pending
// and resolved.
//
// `--id` rows are looked up one by one, so a missing id is named even when
// the other selectors would have excluded it. The other selectors then
// narrow the named ids the same way they narrow a plain `--run` or
// `--skill` cut. A query with no id list reads every matching row, with no
// hidden limit: a report is not a preview.
func selectReportMarkers(opened *store.Store, options reportOptions) (reportSelection, error) {
	var selection reportSelection

	var wanted []int64
	for _, id := range options.ids {
		if !containsInt(wanted, id) {
			wanted = append(wanted, id)
		}
	}

	if len(wanted) > 0 {
		for _, id := range wanted {
			row, err := opened.ReadInvocation(id)
			if err != nil {
				return selection, err
			}
			if row == nil {
				selection.missing = append(selection.missing, id)
				continue
			}
			if options.run != "" && row.Session != options.run &&
				row.T3Thread != options.run && row.Parent != options.run {
				continue
			}
			if options.skill != "" && row.Skill != options.skill {
				continue
			}
			recordReportRow(*row, &selection.pending, &selection.resolved)
		}
		return selection, nil
	}

	filters := store.Filters{
		Skill: options.skill,
		Run:   options.run,
		// Zero means every matching row; the report must not cap a
		// selection.
		Limit: 0,
	}
	rows, err := opened.Rows(filters)
	if err != nil {
		return selection, err
	}
	for _, row := range rows {
		recordReportRow(row, &selection.pending, &selection.resolved)
	}
	return selection, nil
}

// existingReport is what a report file already holds, and the lines it
// cannot read.
type existingReport struct {
	markers []string
	bad     []string
}

// parseReport is the markers in a report's text, plus any line that is not
// one.
//
// A report is tool-owned: every non-blank line is a marker. A line that is
// not one is reported with its position rather than dropped, because
// rewriting the file would otherwise delete whatever a person wrote there
// without a word.
func parseReport(text, relative string) existingReport {
	var report existingReport
	for i, line := range strings.Split(text, "\n") {
		value := strings.TrimSpace(line)
		if value == "" {
			continue
		}
		parsed, ok := marker.Parse(value)
		if !ok {
			report.bad = append(report.bad,
				relative+":"+formatInt(int64(i+1))+
					": not a marker (machine#id): "+format.Sanitize(value))
			continue
		}
		report.markers = append(report.markers, parsed.Text())
	}
	return report
}

// writeReportJSON is the write path's flat JSON object.
//
// `path` is empty and `trailer` carries the line in trailer mode; the
// keys are the same in both modes, so a consumer reads one shape.
func writeReportJSON(path string, markers, resolved []string, already, dryRun bool, trailer string) string {
	var out []byte
	out = append(out, `{"path":`...)
	out = append(out, format.JSONString(path)...)
	out = append(out, `,"markers":`...)
	out = append(out, format.JSONStrings(markers)...)
	out = append(out, `,"already_resolved":`...)
	out = append(out, format.JSONStrings(resolved)...)
	out = append(out, `,"already_reported":`...)
	out = append(out, format.JSONBool(already)...)
	out = append(out, `,"dry_run":`...)
	out = append(out, format.JSONBool(dryRun)...)
	out = append(out, `,"trailer":`...)
	out = append(out, format.JSONString(trailer)...)
	out = append(out, '}')
	return string(out)
}

// resolvedNotes is one stderr note per row a previous change already
// closed.
func resolvedNotes(resolved []string) string {
	lines := make([]string, 0, len(resolved))
	for _, item := range resolved {
		lines = append(lines, item+" already resolved; skipped")
	}
	return format.Prefixed(lines)
}

// nothingOutcome is the answer when the selection produced no marker to
// write at all.
func nothingOutcome(options reportOptions, resolved []string, notes string) Outcome {
	if options.json {
		return OKNotes(writeReportJSON("", nil, resolved, false, options.dryRun, ""), notes)
	}
	return OKNotes("nothing to report: the selected rows are already resolved", notes)
}

// trailerOutcome is trailer mode: print the line, write nothing.
//
// The line is the transport here. The note says why nothing was written
// and where the line belongs, so the caller does not go looking for a file
// that this checkout does not have.
func trailerOutcome(pending, resolved []string, notes string, options reportOptions) Outcome {
	if len(pending) == 0 {
		return nothingOutcome(options, resolved, notes)
	}
	line := trailerKey + ": " + strings.Join(pending, ", ")
	allNotes := notes
	if allNotes != "" {
		allNotes += "\n"
	}
	allNotes += "skill-log: no " + reportDir +
		"/ here; put the trailer in the commit body"
	if options.json {
		return OKNotes(writeReportJSON("", pending, resolved, false, options.dryRun, line), allNotes)
	}
	return OKNotes(line, allNotes)
}

// checkResult is a report's markers, the lines that are not markers, and
// warnings.
type checkResult struct {
	markers  []string
	problems []string
	warnings []string
}

// validateReport checks every line of a report against the marker grammar
// and the store.
//
// A marker this store does not hold is a warning: it names a row on a
// machine whose store has not been merged here, and that machine will
// resolve it. An already-resolved row is a warning too. A line that is
// not a marker is a problem — the merge cannot interpret it.
func validateReport(text, relative string, opened *store.Store, haveStore bool) (checkResult, error) {
	var result checkResult
	for i, line := range strings.Split(text, "\n") {
		value := strings.TrimSpace(line)
		if value == "" {
			continue
		}
		parsed, ok := marker.Parse(value)
		if !ok {
			result.problems = append(result.problems,
				relative+":"+formatInt(int64(i+1))+
					": not a marker (machine#id): "+format.Sanitize(value))
			continue
		}
		textMarker := parsed.Text()
		result.markers = append(result.markers, textMarker)
		if !haveStore {
			continue
		}
		row, err := opened.ReadInvocation(parsed.ID)
		if err != nil {
			return result, err
		}
		if row == nil {
			result.warnings = append(result.warnings,
				textMarker+": not in this db (resolves where it is)")
			continue
		}
		if row.Machine != parsed.Machine {
			result.warnings = append(result.warnings,
				textMarker+": not in this db (resolves where it is)")
			continue
		}
		if row.Fix != "" {
			result.warnings = append(result.warnings,
				textMarker+": already resolved by "+firstNine(row.Fix))
		}
	}
	return result, nil
}

// checkOutcome is the `--check` answer: validate, never write, exit 1 on a
// problem.
func checkOutcome(path, relative, storePath string, artifact, asJSON bool) Outcome {
	if !artifact {
		if asJSON {
			return OK(`{"path":"","markers":[],"problems":[],"warnings":[]}`)
		}
		return OK("no " + reportDir +
			"/ here: this checkout resolves from the " +
			trailerKey + " trailer")
	}

	if !isRegularFile(path) {
		if asJSON {
			return OK(`{"path":` + format.JSONString(relative) +
				`,"markers":[],"problems":[],"warnings":[]}`)
		}
		return OK("no report file at " + relative)
	}

	var opened *store.Store
	haveStore := false
	var storeWarning []string
	store, refusal, err := store.OpenRead(storePath)
	if err != nil {
		storeWarning = append(storeWarning, "store unavailable: "+err.Error())
	} else if refusal != nil {
		storeWarning = append(storeWarning,
			"store unavailable: "+refusalFailure(refusal).Message)
	} else if store != nil {
		opened = store
		defer opened.Close()
		// A table-less (or unreadable) store still lets the syntax be
		// checked: the marker lookup is what it cannot answer.
		ours, err := opened.IsOurs()
		if err != nil {
			storeWarning = append(storeWarning, "store unavailable: "+err.Error())
		} else {
			haveStore = ours
		}
	}

	text, err := format.ReadText(path)
	if err != nil {
		// The store classifies the failure and this handler renders it:
		// damage is damage, a lock is a lock, and nothing here inspects a
		// SQLite message (SPEC §3).
		failure := readFailure(storePath, err)
		return Fail(failure.Message, failure.Code)
	}
	result, err := validateReport(text, relative, opened, haveStore)
	if err != nil {
		failure := readFailure(storePath, err)
		return Fail(failure.Message, failure.Code)
	}

	warnings := make([]string, 0, len(storeWarning)+len(result.warnings))
	warnings = append(warnings, storeWarning...)
	warnings = append(warnings, result.warnings...)

	if asJSON {
		var out []byte
		out = append(out, `{"path":`...)
		out = append(out, format.JSONString(relative)...)
		out = append(out, `,"markers":`...)
		out = append(out, format.JSONStrings(result.markers)...)
		out = append(out, `,"problems":`...)
		out = append(out, format.JSONStrings(result.problems)...)
		out = append(out, `,"warnings":`...)
		out = append(out, format.JSONStrings(warnings)...)
		out = append(out, '}')
		if len(result.problems) > 0 {
			failed := FailNotes(problemsLine(len(result.problems)), ExitFailure, "")
			failed.Text = string(out)
			return failed
		}
		return OK(string(out))
	}

	notes := format.Prefixed(warnings)
	if len(result.problems) > 0 {
		allNotes := format.Prefixed(result.problems)
		if notes != "" {
			allNotes += "\n" + notes
		}
		return FailNotes(relative+" is not a valid report", ExitFailure, allNotes)
	}
	return OKNotes(relative+" is valid ("+markerCount(len(result.markers))+")", notes)
}

// isRegularFile reports whether path is a file.
func isRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// isDirectory reports whether path is a directory.
func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func handleReport(args []string) Outcome {
	options, err := parseReportOptions(args)
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
			"report runs inside a git checkout (the report lives there)",
			ExitFailure,
		)
	}

	slugSource := options.slug
	if slugSource == "" {
		branch := settings.GitBranch(root)
		// A detached HEAD is called `HEAD`, which is not a branch name;
		// an empty answer is "not a repository", which cannot happen here.
		if branch == "HEAD" || branch == "" {
			return Fail(
				"cannot name the report file (detached HEAD?); pass --slug",
				ExitFailure,
			)
		}
		slugSource = branch
	}
	slug := branchSlug(slugSource)
	if slug == "" {
		return Fail(
			"cannot name the report file (detached HEAD?); pass --slug",
			ExitFailure,
		)
	}

	relative := reportDir + "/" + slug + ".md"
	path := filepath.Join(root, filepath.FromSlash(relative))
	artifact := isDirectory(filepath.Join(root, filepath.FromSlash(reportDir)))
	storePath := settings.ResolveDB(options.db)

	if options.check {
		return checkOutcome(path, relative, storePath, artifact, options.json)
	}

	opened, refusal, err := store.OpenRead(storePath)
	if err != nil {
		return Fail(
			"cannot read the store: "+storePath+": "+err.Error(),
			ExitFailure,
		)
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return Fail(failure.Message, failure.Code)
	}
	if opened == nil {
		return Fail(
			"no store at "+storePath+" (run add first)", ExitFailure,
		)
	}
	defer opened.Close()

	var selection reportSelection
	tableless := false
	ours, err := opened.IsOurs()
	if err != nil {
		failure := readFailure(storePath, err)
		return Fail(failure.Message, failure.Code)
	}
	if ours {
		// A store with no tables yet is an empty log: nothing matches,
		// and every named id is a missing id.
		selection, err = selectReportMarkers(opened, options)
		if err != nil {
			failure := readFailure(storePath, err)
			return Fail(failure.Message, failure.Code)
		}
	} else {
		tableless = true
	}

	if tableless && len(options.ids) > 0 {
		var wanted []int64
		for _, id := range options.ids {
			if !containsInt(wanted, id) {
				wanted = append(wanted, id)
			}
		}
		selection.missing = wanted
	}

	if len(selection.missing) > 0 {
		return Fail(
			"no invocation "+joinInts(selection.missing)+" in "+storePath,
			ExitFailure,
		)
	}

	pending := sortedUnique(selection.pending)
	resolved := sortedUnique(selection.resolved)
	notes := resolvedNotes(resolved)

	// A report only carries markers that parse back to the same row.
	// `add` refuses a machine that cannot appear in one, but a row can
	// predate that check or come from another store; writing it would put
	// a line in the file no resolver can read.
	for _, item := range pending {
		parsed, ok := marker.Parse(item)
		if !ok || parsed.Text() != item {
			return Fail(
				"cannot report "+format.Sanitize(item)+
					": not a marker (machine#id)",
				ExitFailure,
			)
		}
	}

	if !artifact {
		return trailerOutcome(pending, resolved, notes, options)
	}

	var existing existingReport
	if isRegularFile(path) {
		text, err := format.ReadText(path)
		if err != nil {
			return Fail(
				"cannot read the report: "+path+": "+err.Error(),
				ExitFailure,
			)
		}
		existing = parseReport(text, relative)
	}
	if len(existing.bad) > 0 {
		return FailNotes(
			relative+" is not a valid report", ExitFailure,
			format.Prefixed(existing.bad),
		)
	}

	existingSorted := sortedUnique(existing.markers)
	existingCount := len(existingSorted)
	merged := existingSorted
	for _, item := range pending {
		merged = addSorted(merged, item)
	}

	if len(merged) == 0 {
		return nothingOutcome(options, resolved, notes)
	}

	already := existingCount > 0 && len(merged) == existingCount

	if !options.dryRun && !already {
		text := strings.Join(merged, "\n") + "\n"
		if err := format.WriteText(path, text); err != nil {
			return Fail(
				"cannot write the report: "+path+": "+err.Error(),
				ExitFailure,
			)
		}
	}

	if options.json {
		return OKNotes(
			writeReportJSON(relative, merged, resolved, already, options.dryRun, ""),
			notes,
		)
	}
	if already {
		return OKNotes(
			"already reported: "+relative+" ("+markerCount(len(merged))+")",
			notes,
		)
	}
	verb := "reported"
	if options.dryRun {
		verb = "would report"
	}
	return OKNotes(
		verb+" "+markerCount(len(merged))+" in "+relative, notes,
	)
}
