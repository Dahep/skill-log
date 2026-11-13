package cli

import (
	"path/filepath"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

// The report directory, relative to the checkout's root. Its presence puts a
// checkout in artifact mode; its absence is trailer mode.
const reportDir = ".skill-log/reports"

// The commit-body trailer a checkout without the report directory uses.
const trailerKey = "Skill-log-Fix"

// The longest file-name slug. A branch name can be long; a report name does not
// need to be.
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
		// The dispatcher reads this to tell `--run -h` from a help request.
		ValueFlags: reportFlags(&reportOptions{}).names(),
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

func reportFlags(options *reportOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--id", "an id", func(value string) error {
		id, err := parsePositive(value, "--id takes a positive integer")
		if err != nil {
			return err
		}
		options.ids = append(options.ids, id)
		return nil
	})
	flags.value("--run", "an id", func(value string) error { options.run = value; options.givenRun = true; return nil })
	flags.value("--skill", "a name", func(value string) error { options.skill = value; options.givenSkill = true; return nil })
	flags.value("--slug", "a name", func(value string) error { options.slug = value; options.givenSlug = true; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	return flags
}

func parseReportOptions(args []string) (reportOptions, error) {
	var options reportOptions
	flags := reportFlags(&options)
	flags.switchFlag("--check", func() error { options.check = true; return nil })
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
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

// branchSlug is the report file's name for a branch: lowercase, safe, truncated.
// Every run of characters outside `[a-z0-9._-]` becomes one `-`.
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

func containsInt(items []int64, value int64) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

// addSorted is items plus value, sorted and without a duplicate. Insertion rather
// than a sort: these lists are tiny.
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

func sortedUnique(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = addSorted(out, item)
	}
	return out
}

func joinInts(items []int64) string {
	parts := make([]string, 0, len(items))
	for _, item := range items {
		parts = append(parts, formatInt(item))
	}
	return strings.Join(parts, ", ")
}

func problemsLine(count int) string {
	if count == 1 {
		return "report check failed: 1 line is not a marker"
	}
	return "report check failed: " + formatInt(int64(count)) + " lines are not markers"
}

func markerCount(count int) string {
	if count == 1 {
		return "1 marker"
	}
	return formatInt(int64(count)) + " markers"
}

// hash.
func firstNine(text string) string {
	if len(text) <= 9 {
		return text
	}
	return text[:9]
}

// reportSelection is what the selectors found: markers to write, rows already
// closed, and ids the store does not have. `missing` is a failure.
type reportSelection struct {
	pending  []string
	resolved []string
	missing  []int64
}

// list (resolved).
func recordReportRow(row store.Invocation, pending, resolved *[]string) {
	text := marker.Format(row.Machine, row.ID)
	if row.Fix != "" {
		*resolved = append(*resolved, text)
		return
	}
	*pending = append(*pending, text)
}

// selectReportMarkers is the markers the selectors name, split into pending and
// resolved. A query with no id list reads every matching row.
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
		// Zero means every matching row; the report must not cap a selection.
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

// cannot read.
type existingReport struct {
	markers []string
	bad     []string
}

// parseReport is the markers in a report's text, plus any line that is not one.
// A report is tool-owned, so such a line is reported with its position.
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

// writeReportJSON is the write path's flat JSON object. `path` is empty and
// `trailer` carries the line in trailer mode; the keys are the same.
func writeReportJSON(path string, markers, resolved []string, already, dryRun bool, trailer string) string {
	return format.Object(
		format.Str("path", path),
		format.Raw("markers", format.JSONStrings(markers)),
		format.Raw("already_resolved", format.JSONStrings(resolved)),
		format.Bool("already_reported", already),
		format.Bool("dry_run", dryRun),
		format.Str("trailer", trailer),
	)
}

// closed.
func resolvedNotes(resolved []string) string {
	lines := make([]string, 0, len(resolved))
	for _, item := range resolved {
		lines = append(lines, item+" already resolved; skipped")
	}
	return prefixedNotes(lines)
}

// write at all.
func nothingOutcome(options reportOptions, resolved []string, notes string) Outcome {
	if options.json {
		return OKNotes(writeReportJSON("", nil, resolved, false, options.dryRun, ""), notes)
	}
	return OKNotes("nothing to report: the selected rows are already resolved", notes)
}

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

// warnings.
type checkResult struct {
	markers  []string
	problems []string
	warnings []string
}

// validateReport checks every line of a report against the marker grammar and the
// store. A marker this store lacks is a warning; a line that is no marker is a problem.
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

// problem.
func checkOutcome(path, relative, storePath string, artifact, asJSON bool) Outcome {
	if !artifact {
		if asJSON {
			return OK(format.Object(format.Str("path", ""), format.Raw("markers", "[]"), format.Raw("problems", "[]"), format.Raw("warnings", "[]")))
		}
		return OK("no " + reportDir +
			"/ here: this checkout resolves from the " +
			trailerKey + " trailer")
	}

	if !format.IsRegularFile(path) {
		if asJSON {
			return OK(format.Object(format.Str("path", relative), format.Raw("markers", "[]"), format.Raw("problems", "[]"), format.Raw("warnings", "[]")))
		}
		return OK("no report file at " + relative)
	}

	opened, refusal, storeErr := store.Open(storePath, false)
	storeWarning := ""
	switch {
	case storeErr != nil:
		storeWarning = "store unavailable: " + readFailure(storePath, storeErr).Message
	case refusal != nil:
		storeWarning = "store unavailable: " + refusalFailure(refusal).Message
	case opened == nil:
		storeWarning = "store unavailable: no store at " + storePath
	}
	haveStore := opened != nil
	if opened != nil {
		defer opened.Close()
	}

	text, err := format.ReadText(path)
	if err != nil {
		return Fail("cannot read the report: "+path+": "+err.Error(), ExitFailure)
	}
	result, err := validateReport(text, relative, opened, haveStore)
	if err != nil {
		failure := readFailure(storePath, err)
		return Fail(failure.Message, failure.Code)
	}

	return reportCheckOutcome(relative, storeWarning, result, asJSON)
}

func reportCheckOutcome(relative, storeWarning string, result checkResult, asJSON bool) Outcome {
	warnings := make([]string, 0, 1+len(result.warnings))
	if storeWarning != "" {
		warnings = append(warnings, storeWarning)
	}
	warnings = append(warnings, result.warnings...)

	if asJSON {
		out := format.Object(
			format.Str("path", relative),
			format.Raw("markers", format.JSONStrings(result.markers)),
			format.Raw("problems", format.JSONStrings(result.problems)),
			format.Raw("warnings", format.JSONStrings(warnings)),
		)
		if len(result.problems) > 0 {
			failed := FailNotes(problemsLine(len(result.problems)), ExitFailure, "")
			failed.Text = out
			return failed
		}
		return OK(out)
	}

	notes := prefixedNotes(warnings)
	if len(result.problems) > 0 {
		allNotes := prefixedNotes(result.problems)
		if notes != "" {
			allNotes += "\n" + notes
		}
		return FailNotes(relative+" is not a valid report", ExitFailure, allNotes)
	}
	return OKNotes(relative+" is valid ("+markerCount(len(result.markers))+")", notes)
}

func handleReport(args []string) Outcome {
	options, err := parseReportOptions(args)
	if err != nil {
		return usageOutcome(err)
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
		// A detached HEAD is called `HEAD`, which is not a branch name.
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
	artifact := format.IsDir(filepath.Join(root, filepath.FromSlash(reportDir)))
	storePath := settings.ResolveDB(options.db)

	if options.check {
		return checkOutcome(path, relative, storePath, artifact, options.json)
	}

	opened, failure := openStore(storePath, false)
	if failure != nil {
		return Fail(failure.Message, failure.Code)
	}
	if opened == nil {
		return Fail("no store at "+storePath+" (run add first)", ExitFailure)
	}
	defer opened.Close()

	var selection reportSelection
	// A store with no tables yet is an empty log: every named id is a missing id.
	selection, err = selectReportMarkers(opened, options)
	if err != nil {
		failure := readFailure(storePath, err)
		return Fail(failure.Message, failure.Code)
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

	// A report only carries markers that parse back to the same row: an
	// unparseable marker would put a line in the file no resolver can read.
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
	if format.IsRegularFile(path) {
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
			prefixedNotes(existing.bad),
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
