package cli

import (
	"os"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

type addOptions struct {
	skill     string
	problems  []string
	dryRun    bool
	json      bool
	db        string
	adapters  []string
	evidence  string
	ref       string
	skillsDir string
	// context collects the context flags by column, for ResolveContext.
	context map[string]string
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
			"                   [--evidence <grade>] [--ref <call-id>]\n" +
			"                   [--skills-dir <dir>] [--adapter <name>]...\n" +
			"                   [--dry-run] [--json] [--db <path>]",
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
			"line — up to the first newline — and at most 64 KiB.\n" +
			"\n" +
			"--evidence says how the skill was in play: attested (the\n" +
			"default), listed or body. call and read are refused, because\n" +
			"only harvest can prove them. --ref names the harness call this\n" +
			"row is about: when a row already carries it the problems append\n" +
			"there, and no second invocation is written.\n" +
			"\n" +
			"--skills-dir, or SKILL_LOG_SKILLS_DIR, refuses a skill name the\n" +
			"directory does not hold: a row naming a skill that does not\n" +
			"exist skews every rate it appears in.",
		Handle: handleAdd,
	}
}

func init() { register(addVerb()) }

func addFlags(options *addOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--skill", "a name", func(value string) error { options.skill = value; return nil })
	flags.value("--problem", "a text", func(value string) error { options.problems = append(options.problems, value); return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	// The context flags come from the precedence table: one descriptor per
	// column carries the flag's name and its value description.
	for _, field := range settings.ContextFields() {
		flags.value(field.Flag, field.What, func(value string) error {
			if options.context == nil {
				options.context = map[string]string{}
			}
			options.context[field.Column] = value
			return nil
		})
	}
	flags.value("--adapter", "a name", func(value string) error { options.adapters = append(options.adapters, value); return nil })
	flags.value("--evidence", "a grade", func(value string) error { options.evidence = value; return nil })
	flags.value("--ref", "a call id", func(value string) error { options.ref = value; return nil })
	flags.value("--skills-dir", "a directory", func(value string) error { options.skillsDir = value; return nil })
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
	if options.evidence == "" {
		options.evidence = "attested"
	}
	switch options.evidence {
	case "body", "listed", "attested":
	case "call", "read":
		return options, usageError{"--evidence " + options.evidence +
			" is proved by harvest, not asserted: use body, listed or attested"}
	default:
		return options, usageError{"--evidence takes body, listed or attested"}
	}
	return options, nil
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
	// One pass answers both: the toplevel is the worktree, and the repo is
	// the name that checkout belongs to.
	detectedRepo, detectedWorktree := settings.DetectCheckout()
	resolved, err := settings.ResolveContext(options.context, options.adapters, settings.Detected{
		Repo:     detectedRepo,
		Worktree: detectedWorktree,
	})
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	var row store.Invocation
	row.Skill = strings.TrimSpace(options.skill)
	row.Harness = resolved.Harness
	row.Session = resolved.Session
	row.Parent = resolved.Parent
	row.Model = resolved.Model
	row.Repo = resolved.Repo
	row.Worktree = resolved.Worktree
	row.Project = resolved.Project
	row.T3Thread = resolved.T3Thread
	row.Machine = resolved.Machine
	row.Evidence = options.evidence
	row.EvidenceRef = strings.TrimSpace(options.ref)

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

	skillsDir := settings.ResolveSkillsDir(options.skillsDir)
	if skillsDir != "" {
		found, err := skillExists(skillsDir, row.Skill)
		if err != nil {
			return Fail("cannot read the skills directory "+skillsDir+
				": it is not a directory this user can read", ExitFailure)
		}
		if !found {
			return Fail("usage: no skill named "+row.Skill+" in "+skillsDir+
				": a row naming a skill that does not exist skews every rate it appears in",
				ExitUsage)
		}
	}

	now := settings.LocalTimestamp()
	// --ref narrows the non-idempotency: when a row already carries the call,
	// the problems append to it and no second invocation is written.
	if row.EvidenceRef != "" {
		added, refusal, err := store.WriteOrAppendToRef(
			path, &row, clean, now, options.dryRun)
		if failure := writeOutcome(path, refusal, err); failure != nil {
			return Fail(failure.Message, failure.Code)
		}
		if added.Row != nil {
			if options.json {
				return OK(RenderRowJSON(*added.Row))
			}
			return OK(marker.Format(added.Row.Machine, added.Row.ID))
		}
	}

	if options.dryRun {
		row.TS = now
		row.Problems = clean
		return OK(RenderRowJSON(row))
	}

	result, err := store.WriteInvocation(path, &row, clean, now)
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

// skillExists reports whether dir holds a skill of this name: a directory
// carrying its own SKILL.md. A missing or unreadable directory is an error, so
// the caller can name it rather than call every skill unknown.
func skillExists(dir, name string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		if entry.Name() == name {
			return isSkillDir(dir, name), nil
		}
	}
	return false, nil
}
