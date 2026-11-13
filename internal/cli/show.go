package cli

import (
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

const (
	lastMin = 1
	lastMax = 500
)

func lastRangeMessage() string { return "--last takes a number between 1 and 500" }

type showOptions struct {
	skill        string
	machine      string
	harness      string
	repo         string
	run          string
	unresolved   bool
	last         int
	json         bool
	db           string
	givenSkill   bool
	givenMachine bool
	givenHarness bool
	givenRepo    bool
	givenRun     bool
}

func showVerb() Verb {
	return Verb{
		Name:    "show",
		Summary: "read the log back: recent invocations and their problems",
		Usage: "skill-log show [--skill <name>] [--machine <name>]\n" +
			"                   [--harness <name>] [--repo <name>] [--run <id>]\n" +
			"                   [--unresolved] [--last <n>] [--json] [--db <path>]",
		Examples: []string{
			"skill-log show",
			"skill-log show --skill diagnosing-bugs --last 5",
			"skill-log show --unresolved --json",
		},
		ValueFlags: showFlags(&showOptions{}).names(),
		Notes: "Rows come back newest first. The table indents each problem\n" +
			"under the invocation it belongs to, and shortens a worktree\n" +
			"under your home directory to ~/.\n" +
			"\n" +
			"--run names a run in whichever namespace it was recorded in:\n" +
			"its session, its T3 thread or its parent. Matching all three\n" +
			"is what finds the tree around a run, not one row of it.\n" +
			"\n" +
			"--last takes a number between 1 and 500, 20 by default;\n" +
			"--unresolved keeps only the rows no commit has stamped yet.\n" +
			"\n" +
			"A filter that matches nothing says which filter it was, so\n" +
			"an empty answer is never mistaken for an empty log.\n" +
			"\n" +
			"--json prints one flat object per line, with every column,\n" +
			"the marker and the problems. An empty log prints nothing at\n" +
			"all, so the stream stays valid JSON lines.\n" +
			"\n" +
			"A read never writes: it creates no store and changes none.",
		Handle: handleShow,
	}
}

func init() { register(showVerb()) }

func parseLast(text string) (int, error) {
	if text == "" {
		return 0, usageError{lastRangeMessage()}
	}
	value := 0
	for _, c := range text {
		if c < '0' || c > '9' {
			return 0, usageError{lastRangeMessage()}
		}
		value = value*10 + int(c-'0')
		if value > lastMax {
			return 0, usageError{lastRangeMessage()}
		}
	}
	if value < lastMin {
		return 0, usageError{lastRangeMessage()}
	}
	return value, nil
}

func showFlags(options *showOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--skill", "a name", func(value string) error { options.skill = value; options.givenSkill = true; return nil })
	flags.value("--machine", "a name", func(value string) error { options.machine = value; options.givenMachine = true; return nil })
	flags.value("--harness", "a name", func(value string) error { options.harness = value; options.givenHarness = true; return nil })
	flags.value("--repo", "a name", func(value string) error { options.repo = value; options.givenRepo = true; return nil })
	flags.value("--run", "an id", func(value string) error { options.run = value; options.givenRun = true; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	flags.value("--last", "a number", func(value string) error {
		last, err := parseLast(value)
		if err != nil {
			return err
		}
		options.last = last
		return nil
	})
	return flags
}

func parseShowOptions(args []string) (showOptions, error) {
	options := showOptions{last: store.DefaultLimit}
	flags := showFlags(&options)
	flags.switchFlag("--unresolved", func() error { options.unresolved = true; return nil })
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
	}
	// An empty filter value selects nothing, which is never what the caller
	// meant: it is a usage error rather than a silently empty result.
	if options.givenSkill && strings.TrimSpace(options.skill) == "" {
		return options, usageError{"--skill needs a name"}
	}
	if options.givenMachine && strings.TrimSpace(options.machine) == "" {
		return options, usageError{"--machine needs a name"}
	}
	if options.givenHarness && strings.TrimSpace(options.harness) == "" {
		return options, usageError{"--harness needs a name"}
	}
	if options.givenRepo && strings.TrimSpace(options.repo) == "" {
		return options, usageError{"--repo needs a name"}
	}
	if options.givenRun && strings.TrimSpace(options.run) == "" {
		return options, usageError{"--run needs an id"}
	}
	return options, nil
}

func showEmptyMessage(filters store.Filters) string {
	var parts []string
	if filters.Skill != "" {
		parts = append(parts, "--skill "+format.Sanitize(filters.Skill))
	}
	if filters.Machine != "" {
		parts = append(parts, "--machine "+format.Sanitize(filters.Machine))
	}
	if filters.Harness != "" {
		parts = append(parts, "--harness "+format.Sanitize(filters.Harness))
	}
	if filters.Repo != "" {
		parts = append(parts, "--repo "+format.Sanitize(filters.Repo))
	}
	if filters.Run != "" {
		parts = append(parts, "--run "+format.Sanitize(filters.Run))
	}
	if len(parts) == 0 {
		return "no invocations logged yet"
	}
	return "no invocations match " + strings.Join(parts, " and ")
}

func showTableColumns() []format.Column[store.Invocation] {
	return []format.Column[store.Invocation]{
		{Name: "inv", Cell: func(row store.Invocation) string { return formatInt(row.ID) }},
		{Name: "ts", Cell: func(row store.Invocation) string { return format.Sanitize(row.TS) }},
		{Name: "machine", Cell: func(row store.Invocation) string { return format.Sanitize(row.Machine) }},
		{Name: "harness", Cell: func(row store.Invocation) string { return format.Sanitize(row.Harness) }},
		{Name: "session", Cell: func(row store.Invocation) string { return format.Sanitize(row.Session) }},
		{Name: "parent", Cell: func(row store.Invocation) string { return format.Sanitize(row.Parent) }},
		{Name: "model", Cell: func(row store.Invocation) string { return format.Sanitize(row.Model) }},
		{Name: "repo", Cell: func(row store.Invocation) string { return format.Sanitize(row.Repo) }},
		{Name: "worktree", Cell: func(row store.Invocation) string { return format.ShortenHome(format.Sanitize(row.Worktree)) }},
		{Name: "project", Cell: func(row store.Invocation) string { return format.Sanitize(row.Project) }},
		{Name: "t3_thread", Cell: func(row store.Invocation) string { return format.Sanitize(row.T3Thread) }},
		{Name: "skill", Cell: func(row store.Invocation) string { return format.Sanitize(row.Skill) }},
		{Name: "fix", Cell: func(row store.Invocation) string { return format.Sanitize(row.Fix) }},
		{Name: "resolved_at", Cell: func(row store.Invocation) string { return format.Sanitize(row.ResolvedAt) }},
		{Name: "problems", Cell: func(row store.Invocation) string { return "" }, Under: showProblemLines},
	}
}

func showProblemLines(row store.Invocation) []string {
	lines := make([]string, 0, len(row.Problems))
	for i, problem := range row.Problems {
		lines = append(lines, "    problem "+formatInt(int64(i+1))+": "+problem)
	}
	return lines
}

func renderShowTable(rows []store.Invocation) string {
	return format.JoinLines(format.TableLines(showTableColumns(), rows))
}

func handleShow(args []string) Outcome {
	options, err := parseShowOptions(args)
	if err != nil {
		return usageOutcome(err)
	}
	path := settings.ResolveDB(options.db)
	filters := store.Filters{
		Skill:      strings.TrimSpace(options.skill),
		Machine:    strings.TrimSpace(options.machine),
		Harness:    strings.TrimSpace(options.harness),
		Repo:       strings.TrimSpace(options.repo),
		Run:        strings.TrimSpace(options.run),
		Unresolved: options.unresolved,
		Limit:      options.last,
	}

	opened, failure := openStore(path, false)
	if failure != nil {
		return Fail(failure.Message, failure.Code)
	}

	var rows []store.Invocation
	if opened != nil {
		defer opened.Close()
		// A store with no tables yet is an empty log: the read answers
		// with no rows rather than an error.
		rows, err = opened.Rows(filters)
		if err != nil {
			failure := readFailure(path, err)
			return Fail(failure.Message, failure.Code)
		}
	}

	if len(rows) == 0 {
		if options.json {
			// The JSON stream stays parseable: an empty result prints nothing
			// at all, not an empty object.
			return OK("")
		}
		return OK(showEmptyMessage(filters))
	}
	if options.json {
		lines := make([]string, 0, len(rows))
		for _, row := range rows {
			lines = append(lines, RenderRowJSON(row))
		}
		return OK(format.JoinLines(lines))
	}
	return OK(renderShowTable(rows))
}
