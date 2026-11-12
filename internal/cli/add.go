package cli

import (
	"errors"
	"strings"

	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

type addOptions struct {
	skill    string
	problems []string
	dryRun   bool
	json     bool
	db       string
	harness  string
	session  string
	parent   string
	model    string
	repo     string
	worktree string
	project  string
	t3Thread string
	machine  string
	adapters []string
}

func addVerb() Verb {
	return Verb{
		Name:    "add",
		Summary: "record one skill invocation and the friction it produced",
		Usage: "skill-log add --skill <name> [--problem <text>]...\n" +
			"                   [--harness <name>] [--session <id>] [--parent <id>]\n" +
			"                   [--model <provider/id>] [--repo <name>]\n" +
			"                   [--worktree <path>] [--project <name>]\n" +
			"                   [--t3-thread <id>] [--machine <name>]\n" +
			"                   [--adapter <name>]... [--dry-run] [--json] [--db <path>]",
		Examples: []string{
			"skill-log add --skill diagnosing-bugs",
			`skill-log add --skill diagnosing-bugs --problem "step 3 assumed a core dump exists"`,
			"skill-log add --skill create-skill --problem - < notes.txt",
			"skill-log add --skill create-skill --dry-run --json",
		},
		// The flags that consume the next argument. The dispatcher reads this
		// to tell `--problem -h` (a problem spelled `-h`) from a help request.
		ValueFlags: []string{
			"--skill", "--problem", "--db", "--harness", "--session", "--parent",
			"--model", "--repo", "--worktree", "--project", "--t3-thread",
			"--machine", "--adapter",
		},
		Notes: "A clean run still writes a row: the invocation count is the\n" +
			"denominator of the problems-per-invocation rate.\n" +
			"\n" +
			"add is not idempotent. The log records occurrences, so a retry\n" +
			"after a crashed run is indistinguishable from a genuine repeat\n" +
			"and deduping would hide the second occurrence of one error.\n" +
			"Two identical calls therefore produce two rows.\n" +
			"\n" +
			"Context fields resolve by one chain, per field: the explicit\n" +
			"flag, then its SKILL_LOG_* variable, then an enabled adapter,\n" +
			"then the built-in detection. An empty field means unknown.\n" +
			"The machine is always detected; --machine names it instead.\n" +
			"\n" +
			"Adapters never run unasked. Enable one with --adapter opencode\n" +
			"or SKILL_LOG_ADAPTERS=opencode. Both take a comma-separated\n" +
			"list, and --adapter may be repeated. The opencode adapter\n" +
			"fills harness, session and model; the t3 adapter fills\n" +
			"project. An adapter never sets parent, and its failure is a\n" +
			"blank field rather than an error.\n" +
			"\n" +
			"--problem - reads the problem text from stdin, and exits 2\n" +
			"instead of waiting when stdin is a terminal. The text is one\n" +
			"line — up to the first newline — and at most 64 KiB.",
		Handle: handleAdd,
	}
}

func init() { register(addVerb()) }

func parseAddOptions(args []string) (addOptions, error) {
	var options addOptions
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--skill", "--problem", "--db", "--harness", "--session", "--parent",
			"--model", "--repo", "--worktree", "--project", "--t3-thread",
			"--machine", "--adapter":
			what := map[string]string{
				"--skill": "a name", "--problem": "a text", "--db": "a path",
				"--harness": "a name", "--session": "an id", "--parent": "an id",
				"--model": "provider/id", "--repo": "a name",
				"--worktree": "a path", "--project": "a name",
				"--t3-thread": "an id", "--machine": "a name",
				"--adapter": "a name",
			}[arg]
			value, err := takeValue(args, i, arg, what)
			if err != nil {
				return options, err
			}
			switch arg {
			case "--skill":
				options.skill = value
			case "--problem":
				options.problems = append(options.problems, value)
			case "--db":
				options.db = value
			case "--harness":
				options.harness = value
			case "--session":
				options.session = value
			case "--parent":
				options.parent = value
			case "--model":
				options.model = value
			case "--repo":
				options.repo = value
			case "--worktree":
				options.worktree = value
			case "--project":
				options.project = value
			case "--t3-thread":
				options.t3Thread = value
			case "--machine":
				options.machine = value
			case "--adapter":
				options.adapters = append(options.adapters, value)
			}
			i++
		case "--dry-run":
			options.dryRun = true
		case "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + arg}
		}
	}
	if strings.TrimSpace(options.skill) == "" {
		return options, usageError{"--skill needs a name"}
	}
	// A blank problem carries no friction; it is ignored rather than written
	// as an empty row.
	var kept []string
	for _, problem := range options.problems {
		if strings.TrimSpace(problem) != "" {
			kept = append(kept, problem)
		}
	}
	options.problems = kept
	return options, nil
}

// resolveField is one field of the row, by the precedence chain: the explicit
// flag, then the field's SKILL_LOG_* variable, then the enabled adapter's
// value, then the built-in detection.
func resolveField(flag, variable, adapterValue, detected string) string {
	if strings.TrimSpace(flag) != "" {
		return strings.TrimSpace(flag)
	}
	if strings.TrimSpace(variable) != "" {
		return strings.TrimSpace(variable)
	}
	if strings.TrimSpace(adapterValue) != "" {
		return strings.TrimSpace(adapterValue)
	}
	return strings.TrimSpace(detected)
}

func handleAdd(args []string) Outcome {
	options, err := parseAddOptions(args)
	if err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
	}

	// --problem - reads the text from stdin. On a terminal there is nothing
	// to read and the command would hang, so it refuses instead.
	var problems []string
	for _, text := range options.problems {
		if text == "-" {
			if stdinIsTTY() {
				return Fail("usage: --problem - reads from stdin, and stdin is a terminal", ExitUsage)
			}
			text = readStdinLine()
		}
		if strings.TrimSpace(text) != "" {
			problems = append(problems, text)
		}
	}

	path := settings.ResolveDB(options.db)

	// The worktree comes first: the t3 adapter needs it to find the project,
	// and the adapter's value sits below the flag and the variable.
	detectedWorktree := settings.DetectWorktree()
	worktree := resolveField(
		options.worktree,
		settings.EnvOrEmpty("SKILL_LOG_WORKTREE"),
		"",
		detectedWorktree,
	)

	adapter := settings.ApplyAdapters(settings.EnabledAdapters(options.adapters), worktree)

	var row store.Invocation
	row.Skill = strings.TrimSpace(options.skill)
	row.Harness = resolveField(options.harness, settings.EnvOrEmpty("SKILL_LOG_HARNESS"), adapter.Harness, "")
	row.Session = resolveField(options.session, settings.EnvOrEmpty("SKILL_LOG_SESSION"), adapter.Session, "")
	// An adapter may not set the parent: it names a run this tool did not
	// spawn, and no adapter can know it.
	row.Parent = resolveField(options.parent, settings.EnvOrEmpty("SKILL_LOG_PARENT"), "", "")
	row.Model = resolveField(options.model, settings.EnvOrEmpty("SKILL_LOG_MODEL"), adapter.Model, "")
	// The repository is detected from the worktree the row carries.
	row.Repo = resolveField(
		options.repo, settings.EnvOrEmpty("SKILL_LOG_REPO"), "", settings.DetectRepo(worktree),
	)
	row.Worktree = worktree
	row.Project = resolveField(options.project, settings.EnvOrEmpty("SKILL_LOG_PROJECT"), adapter.Project, "")
	row.T3Thread = resolveField(options.t3Thread, settings.EnvOrEmpty("SKILL_LOG_T3_THREAD"), "", "")
	// The machine is always detected: there is no SKILL_LOG_MACHINE.
	if strings.TrimSpace(options.machine) != "" {
		row.Machine = strings.TrimSpace(options.machine)
	} else {
		name, err := settings.Hostname()
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		row.Machine = name
	}

	// The machine namespaces every marker. A `#` or a control character would
	// make the row unnameable — and a newline would split a report line — so
	// an explicit value that carries one is refused at the boundary.
	if strings.Contains(row.Machine, "#") {
		return Fail("usage: --machine names a marker; it cannot contain '#' or a control character", ExitUsage)
	}
	if formatSanitize(row.Machine) != row.Machine {
		return Fail("usage: --machine names a marker; it cannot contain '#' or a control character", ExitUsage)
	}

	// The problems are sanitized on the way in as well as on the way out.
	clean := make([]string, 0, len(problems))
	for _, problem := range problems {
		clean = append(clean, formatSanitize(problem))
	}

	if options.dryRun {
		row.TS = settings.LocalTimestamp()
		row.Problems = clean
		return OK(RenderRowJSON(row))
	}

	result, err := store.WriteInvocation(path, &row, clean)
	if err != nil {
		return Fail("cannot use the store: "+path+": "+err.Error(), ExitFailure)
	}
	if result.Refusal != nil {
		failure := refusalFailure(result.Refusal)
		return Fail(failure.Message, failure.Code)
	}

	row.ID = result.ID
	row.Problems = clean
	if options.json {
		return OK(RenderRowJSON(row))
	}
	return OK(marker.Format(row.Machine, row.ID))
}
