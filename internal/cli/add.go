package cli

import (
	"strings"

	"github.com/Dahep/skill-log/internal/format"
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
		ValueFlags: addFlags(&addOptions{}).names(),
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

func addFlags(options *addOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--skill", "a name", func(value string) error { options.skill = value; return nil })
	flags.value("--problem", "a text", func(value string) error { options.problems = append(options.problems, value); return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	flags.value("--harness", "a name", func(value string) error { options.harness = value; return nil })
	flags.value("--session", "an id", func(value string) error { options.session = value; return nil })
	flags.value("--parent", "an id", func(value string) error { options.parent = value; return nil })
	flags.value("--model", "provider/id", func(value string) error { options.model = value; return nil })
	flags.value("--repo", "a name", func(value string) error { options.repo = value; return nil })
	flags.value("--worktree", "a path", func(value string) error { options.worktree = value; return nil })
	flags.value("--project", "a name", func(value string) error { options.project = value; return nil })
	flags.value("--t3-thread", "an id", func(value string) error { options.t3Thread = value; return nil })
	flags.value("--machine", "a name", func(value string) error { options.machine = value; return nil })
	flags.value("--adapter", "a name", func(value string) error { options.adapters = append(options.adapters, value); return nil })
	return flags
}

func parseAddOptions(args []string) (addOptions, error) {
	var options addOptions
	flags := addFlags(&options)
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
	}
	if strings.TrimSpace(options.skill) == "" {
		return options, usageError{"--skill needs a name"}
	}
	var kept []string
	for _, problem := range options.problems {
		if strings.TrimSpace(problem) != "" {
			kept = append(kept, problem)
		}
	}
	options.problems = kept
	return options, nil
}

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
		return usageOutcome(err)
	}

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
	detectedWorktree := settings.DetectWorktree()
	worktree := resolveField(
		options.worktree,
		settings.EnvOrEmpty("SKILL_LOG_WORKTREE"),
		"",
		detectedWorktree,
	)

	adapters := settings.EnabledAdapters(options.adapters)
	adapterSession := ""
	if settings.HasAdapter(adapters, "opencode") {
		adapterSession = settings.EnvOrEmpty(settings.OpenCodeSessionEnv)
	}
	session := resolveField(
		options.session,
		settings.EnvOrEmpty("SKILL_LOG_SESSION"),
		adapterSession,
		"",
	)

	adapter := settings.ApplyAdapters(adapters, worktree, session)

	var row store.Invocation
	row.Skill = strings.TrimSpace(options.skill)
	row.Harness = resolveField(options.harness, settings.EnvOrEmpty("SKILL_LOG_HARNESS"), adapter.Harness, "")
	row.Session = session
	row.Parent = resolveField(options.parent, settings.EnvOrEmpty("SKILL_LOG_PARENT"), "", "")
	row.Model = resolveField(options.model, settings.EnvOrEmpty("SKILL_LOG_MODEL"), adapter.Model, "")
	row.Repo = resolveField(
		options.repo, settings.EnvOrEmpty("SKILL_LOG_REPO"), "", settings.DetectRepo(worktree),
	)
	row.Worktree = worktree
	row.Project = resolveField(options.project, settings.EnvOrEmpty("SKILL_LOG_PROJECT"), adapter.Project, "")
	row.T3Thread = resolveField(options.t3Thread, settings.EnvOrEmpty("SKILL_LOG_T3_THREAD"), "", "")
	if strings.TrimSpace(options.machine) != "" {
		row.Machine = strings.TrimSpace(options.machine)
	} else {
		name, err := settings.Hostname()
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		row.Machine = name
	}

	if strings.Contains(row.Machine, "#") {
		return Fail("usage: --machine names a marker; it cannot contain '#' or a control character", ExitUsage)
	}
	if format.Sanitize(row.Machine) != row.Machine {
		return Fail("usage: --machine names a marker; it cannot contain '#' or a control character", ExitUsage)
	}

	clean := make([]string, 0, len(problems))
	for _, problem := range problems {
		clean = append(clean, format.Sanitize(problem))
	}

	if options.dryRun {
		row.TS = settings.LocalTimestamp()
		row.Problems = clean
		return OK(RenderRowJSON(row))
	}

	result, err := store.WriteInvocation(path, &row, clean)
	if failure := writeOutcome(path, result.Refusal, err); failure != nil {
		return Fail(failure.Message, failure.Code)
	}

	row.ID = result.ID
	row.Problems = clean
	if options.json {
		return OK(RenderRowJSON(row))
	}
	return OK(marker.Format(row.Machine, row.ID))
}
