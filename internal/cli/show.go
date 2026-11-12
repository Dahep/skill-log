package cli

import (
	"errors"
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
		ValueFlags: []string{
			"--skill", "--machine", "--harness", "--repo", "--run", "--last", "--db",
		},
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

func parseShowOptions(args []string) (showOptions, error) {
	options := showOptions{last: store.DefaultLimit}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--skill", "--machine", "--harness", "--repo", "--run", "--db", "--last":
			what := map[string]string{
				"--skill": "a name", "--machine": "a name", "--harness": "a name",
				"--repo": "a name", "--run": "an id", "--db": "a path",
				"--last": "a number",
			}[arg]
			value, err := takeValue(args, i, arg, what)
			if err != nil {
				return options, err
			}
			switch arg {
			case "--skill":
				options.skill = value
				options.givenSkill = true
			case "--machine":
				options.machine = value
				options.givenMachine = true
			case "--harness":
				options.harness = value
				options.givenHarness = true
			case "--repo":
				options.repo = value
				options.givenRepo = true
			case "--run":
				options.run = value
				options.givenRun = true
			case "--db":
				options.db = value
			case "--last":
				last, err := parseLast(value)
				if err != nil {
					return options, err
				}
				options.last = last
			}
			i++
		case "--unresolved":
			options.unresolved = true
		case "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + arg}
		}
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

func showTableHeaders() []string {
	return []string{
		"inv", "ts", "machine", "harness", "session", "parent", "model", "repo",
		"worktree", "project", "t3_thread", "skill", "fix", "resolved_at",
	}
}

func showCell(row store.Invocation, column string) string {
	switch column {
	case "inv":
		return formatInt(row.ID)
	case "ts":
		return format.Sanitize(row.TS)
	case "machine":
		return format.Sanitize(row.Machine)
	case "harness":
		return format.Sanitize(row.Harness)
	case "session":
		return format.Sanitize(row.Session)
	case "parent":
		return format.Sanitize(row.Parent)
	case "model":
		return format.Sanitize(row.Model)
	case "repo":
		return format.Sanitize(row.Repo)
	case "worktree":
		return format.ShortenHome(format.Sanitize(row.Worktree))
	case "project":
		return format.Sanitize(row.Project)
	case "t3_thread":
		return format.Sanitize(row.T3Thread)
	case "skill":
		return format.Sanitize(row.Skill)
	case "fix":
		return format.Sanitize(row.Fix)
	case "resolved_at":
		return format.Sanitize(row.ResolvedAt)
	}
	return ""
}

func renderShowTable(rows []store.Invocation) string {
	headers := showTableHeaders()
	widths := make([]int, len(headers))
	for i, header := range headers {
		widths[i] = len([]rune(header))
	}
	for _, row := range rows {
		for c, header := range headers {
			if width := len([]rune(showCell(row, header))); width > widths[c] {
				widths[c] = width
			}
		}
	}
	var lines []string
	var header strings.Builder
	for c, name := range headers {
		if c > 0 {
			header.WriteString("  ")
		}
		if c == len(headers)-1 {
			header.WriteString(name)
		} else {
			header.WriteString(format.Pad(name, widths[c]))
		}
	}
	lines = append(lines, header.String())
	for _, row := range rows {
		var line strings.Builder
		for c, name := range headers {
			if c > 0 {
				line.WriteString("  ")
			}
			if c == len(headers)-1 {
				line.WriteString(showCell(row, name))
			} else {
				line.WriteString(format.Pad(showCell(row, name), widths[c]))
			}
		}
		// Empty columns in the middle still pad, so the right edge is
		// trimmed: trailing spaces are noise no reader needs.
		lines = append(lines, strings.TrimRight(line.String(), " "))
		for i, problem := range row.Problems {
			lines = append(lines, "    problem "+formatInt(int64(i+1))+": "+problem)
		}
	}
	return format.JoinLines(lines)
}

func handleShow(args []string) Outcome {
	options, err := parseShowOptions(args)
	if err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
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

	opened, refusal, err := store.OpenRead(path)
	if err != nil {
		failure := readFailure(path, err)
		return Fail(failure.Message, failure.Code)
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return Fail(failure.Message, failure.Code)
	}

	var rows []store.Invocation
	if opened != nil {
		defer opened.Close()
		ours, err := opened.IsOurs()
		if err != nil {
			failure := readFailure(path, err)
			return Fail(failure.Message, failure.Code)
		}
		// An existing file with no store tables yet is an empty log, not a
		// foreign one.
		if ours {
			rows, err = opened.Rows(filters)
			if err != nil {
				failure := readFailure(path, err)
				return Fail(failure.Message, failure.Code)
			}
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
