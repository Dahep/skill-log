package cli

import (
	"errors"
	"os"
	"sort"
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
	"github.com/Dahep/skill-log/internal/format"
	templatepkg "github.com/Dahep/skill-log/internal/template"
)

// The five actions `adopt` reports.
const (
	actionAppended  = "appended"
	actionRewritten = "rewritten"
	actionUnchanged = "unchanged"
	actionRefused   = "refused"
	actionSkipped   = "skipped"
)

// The actions `template seed` and `template reset` report, one per template.
const (
	templateActionSeeded      = "seeded"
	templateActionWouldSeed   = "would_seed"
	templateActionRefused     = "refused"
	templateActionDeleted     = "deleted"
	templateActionWouldDelete = "would_delete"
	templateActionAbsent      = "absent"
)

// skillsOptions is the flags every `skills` subcommand accepts.
type skillsOptions struct {
	sub         string
	dir         string
	templateDir string
	json        bool
	dryRun      bool
	force       bool
}

func skillsVerb() Verb {
	return Verb{
		Name:    "skills",
		Summary: "audit and adopt a skills directory and manage the usage-log templates",
		Usage: "skill-log skills <subcommand> [options]\n" +
			"\n" +
			"  skill-log skills audit --dir <dir> [--json] [--dry-run]\n" +
			"  skill-log skills adopt --dir <dir> [--force] [--dry-run] [--json]\n" +
			"  skill-log skills template show [--json] [--template-dir <dir>]\n" +
			"  skill-log skills template seed [--force] [--dry-run]\n" +
			"  skill-log skills template reset [--force] [--dry-run]",
		Examples: []string{
			"skill-log skills audit --dir .agents/skills",
			"skill-log skills adopt --dir .agents/skills",
			"skill-log skills template show",
			"skill-log skills template seed --force",
		},
		ValueFlags: skillsFlags(&skillsOptions{}).names(),
		Notes: "The subcommands, not mode flags: audit classifies, template\n" +
			"manages the two shipped defaults, adopt writes. audit is\n" +
			"read-only and exits 1 on any state but ok or vendored.\n" +
			"\n" +
			"adopt appends a block where there is none and rewrites a\n" +
			"stale one; an edited block is rewritten only with --force.\n" +
			"It never touches a byte outside the fence, and a second run\n" +
			"changes nothing. It exits 0 when the directory ends\n" +
			"conformant, 1 when any skill is refused.\n" +
			"\n" +
			"The templates resolve by --template-dir, then\n" +
			"SKILL_LOG_TEMPLATE_DIR, then\n" +
			"${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/, then the\n" +
			"shipped default in the binary. A moved shipped default is\n" +
			"reported with the two commands that adopt it (seed --force,\n" +
			"then adopt) and never applied.\n" +
			"\n" +
			"A vendored skill — one whose frontmatter carries metadata:\n" +
			"with a source: key — is skipped entirely: its wording belongs\n" +
			"to its upstream, not to this tool.\n" +
			"\n" +
			"See `skill-log skills template show --help` for the template\n" +
			"surface, `skill-log skills audit --help` for the states and\n" +
			"`skill-log skills adopt --help` for the write.",
		NestedHelp: true,
		Handle:     handleSkills,
	}
}

func init() { register(skillsVerb()) }

// skillsFlags reads `skills`'s flags.
func skillsFlags(options *skillsOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--dir", "a path", func(value string) error { options.dir = value; return nil })
	flags.value("--template-dir", "a path", func(value string) error { options.templateDir = value; return nil })
	return flags
}

// parseSkillsOptions reads `skills`'s subcommand and its flags.
//
// The first positional is the subcommand; `template` takes a second positional.
func parseSkillsOptions(args []string) (skillsOptions, error) {
	var options skillsOptions
	var positionals []string
	flags := skillsFlags(&options)
	flags.positional = true
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--force", func() error { options.force = true; return nil })
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if _, ok := flags.lookup(arg); ok {
			i++
			continue
		}
		if flags.switches[arg] != nil {
			continue
		}
		if strings.HasPrefix(arg, "--") {
			continue
		}
		positionals = append(positionals, arg)
	}
	if err := flags.parse(args); err != nil {
		return options, err
	}

	if len(positionals) == 0 {
		return options, usageError{"skills needs a subcommand (audit, template, adopt)"}
	}
	options.sub = positionals[0]
	if options.sub == "template" {
		if len(positionals) < 2 {
			return options, usageError{"skills template needs a subcommand (show, seed, reset)"}
		}
		options.sub = "template " + positionals[1]
	} else if len(positionals) > 1 {
		return options, usageError{"skills " + options.sub + " takes no subcommand"}
	}
	return options, nil
}

// movedDefaultNote is the one line that names a moved shipped default, or "".
func movedDefaultNote(usage, review templatepkg.Template) string {
	if !usage.Moved && !review.Moved {
		return ""
	}
	return "the shipped default moved; adopt it with" +
		" 'skill-log skills template seed --force'," +
		" then 'skill-log skills adopt --dir <dir>'"
}

// movedSuffix is the moved-default clause to append to another message, or "".
//
// The failure gets exactly one stderr line, so the clause rides along with it.
func movedSuffix(moved string) string {
	if moved == "" {
		return ""
	}
	return "; " + moved
}

// joinPath is the tool's path spelling: the directory and the name joined with a separator.
//
// The join is deliberately naive rather than filepath.Join's cleaning one.
func joinPath(dir, name string) string { return dir + "/" + name }

// skillDirs returns the skill subdirectories of dir: those holding a `SKILL.md`, sorted.
func skillDirs(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if name == "." || name == ".." {
			continue
		}
		sub := joinPath(dir, name)
		if format.IsDir(sub) && format.IsRegularFile(joinPath(sub, "SKILL.md")) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// skillState is one skill's audit result: its name, path, and state.
type skillState struct {
	skill string
	path  string
	state string
}

// auditSkill returns one skill's state, from its `SKILL.md`.
//
// The current render is the one this skill would get now.
func auditSkill(dir, name string, template templatepkg.Template, command string) (skillState, error) {
	result := skillState{skill: name, path: joinPath(dir, name)}
	docPath := joinPath(result.path, "SKILL.md")
	text, err := format.ReadText(docPath)
	if err != nil {
		return result, errors.New("cannot read " + docPath + ": " + err.Error())
	}
	rendered := document.Render(template.Content, skillName(text, name), command)
	result.state = document.Classify(
		text,
		rendered.TemplateHash,
		rendered.ContentHash,
		document.IsVendored(text),
	)
	return result, nil
}

// adopted is one skill's adoption result: name, path, state, action.
type adopted struct {
	skill  string
	path   string
	state  string
	action string
}

// adoptSkill makes one skill's document conform, and says what happened.
//
// The state is the document's state *before* the run.
func adoptSkill(dir, name string, template templatepkg.Template, command string, force, dryRun bool) (adopted, error) {
	result := adopted{skill: name, path: joinPath(dir, name)}
	docPath := joinPath(result.path, "SKILL.md")
	text, err := format.ReadText(docPath)
	if err != nil {
		return result, errors.New("cannot read " + docPath + ": " + err.Error())
	}

	rendered := document.Render(template.Content, skillName(text, name), command)
	result.state = document.Classify(
		text,
		rendered.TemplateHash,
		rendered.ContentHash,
		document.IsVendored(text),
	)

	if result.state == document.StateVendored {
		result.action = actionSkipped
		return result, nil
	}
	if result.state == document.StateOK {
		result.action = actionUnchanged
		return result, nil
	}
	if result.state == document.StateEdited && !force {
		result.action = actionRefused
		return result, nil
	}

	var updated string
	if result.state == document.StateMissing {
		updated = document.Append(text, rendered.Text)
		result.action = actionAppended
	} else {
		updated = document.Rewrite(text, rendered.Text)
		result.action = actionRewritten
	}
	if !dryRun {
		if err := format.WriteText(docPath, updated); err != nil {
			return result, errors.New("cannot write " + docPath + ": " + err.Error())
		}
	}
	return result, nil
}

// skillName is the skill's frontmatter `name:`, else its directory name.
func skillName(text, dirName string) string {
	if name := document.FrontmatterName(text); name != "" {
		return name
	}
	return dirName
}

// auditJSONLine is one audit object, exactly `skill`, `path`, `state`.
func auditJSONLine(item skillState) string {
	return format.Object(
		format.Str("skill", item.skill),
		format.Str("path", item.path),
		format.Str("state", item.state),
	)
}

// auditTextLine is one audit line for a person: the state, the skill, the path.
func auditTextLine(item skillState) string {
	return item.state + "  " + item.skill + "  " + item.path
}

// adoptJSONLine is one adopt object, exactly `skill`, `path`, `state`, `action`.
func adoptJSONLine(item adopted) string {
	return format.Object(
		format.Str("skill", item.skill),
		format.Str("path", item.path),
		format.Str("state", item.state),
		format.Str("action", item.action),
	)
}

// adoptTextLine is one adopt line for a person: the action, the state, the skill.
func adoptTextLine(item adopted) string {
	return item.action + "  " + item.state + "  " + item.skill + "  " + item.path
}

var skillsValueFlags = skillsFlags(&skillsOptions{}).names()

func skillsFlagValue(arg string) bool {
	for _, name := range skillsValueFlags {
		if name == arg {
			return true
		}
	}
	return false
}

// handleSkills is the `skills` handler: dispatch on the subcommand.
//
// It never prints and never exits: the CLI boundary owns both.
func handleSkills(args []string) Outcome {
	// A bare scan for the subcommand and for help, without parsing values:
	// `--dir --help` treats `--help` as a value of `--dir` only when it follows it.
	wantsHelp := false
	var positionals []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--help" || arg == "-h":
			wantsHelp = true
		case skillsFlagValue(arg):
			i++
		case !strings.HasPrefix(arg, "--"):
			positionals = append(positionals, arg)
		}
	}

	if wantsHelp {
		if len(positionals) == 0 {
			return OK(RenderVerb(skillsVerb()))
		}
		sub := positionals[0]
		if sub == "template" {
			if len(positionals) < 2 {
				return OK(subcommandHelp("template"))
			}
			sub = "template " + positionals[1]
		}
		block := subcommandHelp(sub)
		if block == "" {
			return Fail("unknown subcommand: "+sub, ExitUsage)
		}
		return OK(block)
	}

	options, err := parseSkillsOptions(args)
	if err != nil {
		return usageOutcome(err)
	}

	switch options.sub {
	case "audit":
		return handleAudit(options)
	case "adopt":
		return handleAdopt(options)
	case "template show":
		return handleTemplateShow(options)
	case "template seed":
		return handleTemplateSeed(options)
	case "template reset":
		return handleTemplateReset(options)
	}
	return Fail("unknown subcommand: "+options.sub, ExitUsage)
}

// failWithText fails with message and exit code, but still prints text on stdout.
//
// The findings are the answer; the exit code says the answer is "not clean".
func failWithText(text, message string, code int) Outcome {
	outcome := Fail(message, code)
	outcome.Text = text
	return outcome
}

// handleAudit is `skills audit`: one line per skill, exit 1 on anything but ok/vendored.
func handleAudit(options skillsOptions) Outcome {
	if strings.TrimSpace(options.dir) == "" {
		return Fail("usage: skills audit needs --dir <dir>", ExitUsage)
	}
	dir := strings.TrimSpace(options.dir)

	// The effective template is validated first: a broken template must not
	// silently mark every skill stale.
	templateDir := templatepkg.ResolveDir(options.templateDir)
	template, err := templatepkg.Load(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	review, err := templatepkg.Load(assets.ReviewName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := document.ValidateTemplate(assets.UsageLogName, template.Content); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	moved := movedDefaultNote(template, review)

	// The resolved binary path is the other half of the current render.
	command := templatepkg.ResolvedCommand()
	names := skillDirs(dir)
	if len(names) == 0 {
		return Fail("no skills in "+dir+" (no subdirectory holds a SKILL.md)", ExitFailure)
	}

	var lines []string
	dirty := false
	for _, name := range names {
		item, err := auditSkill(dir, name, template, command)
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		if item.state != document.StateOK && item.state != document.StateVendored {
			dirty = true
		}
		if options.json {
			lines = append(lines, auditJSONLine(item))
		} else {
			lines = append(lines, auditTextLine(item))
		}
	}
	text := format.JoinLines(lines)

	if dirty {
		// The findings are the answer and go to stdout even when the exit code says "not clean".
		return failWithText(
			text,
			"some skills need adoption"+movedSuffix(moved),
			ExitFailure,
		)
	}
	if moved != "" {
		// A moved default is its own failure: the directory may be clean, and still behind.
		return failWithText(text, moved, ExitFailure)
	}
	return OK(text)
}

// handleAdopt is `skills adopt`: make every skill in `--dir` conform.
func handleAdopt(options skillsOptions) Outcome {
	if strings.TrimSpace(options.dir) == "" {
		return Fail("usage: skills adopt needs --dir <dir>", ExitUsage)
	}
	dir := strings.TrimSpace(options.dir)

	// The effective template is validated first: rendering from a broken
	// template would write blocks no skill can log from.
	templateDir := templatepkg.ResolveDir(options.templateDir)
	template, err := templatepkg.Load(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := document.ValidateTemplate(assets.UsageLogName, template.Content); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	command := templatepkg.ResolvedCommand()
	names := skillDirs(dir)
	if len(names) == 0 {
		return Fail("no skills in "+dir+" (no subdirectory holds a SKILL.md)", ExitFailure)
	}

	var lines []string
	refused := false
	for _, name := range names {
		item, err := adoptSkill(dir, name, template, command, options.force, options.dryRun)
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		if item.action == actionRefused {
			refused = true
		}
		if options.json {
			lines = append(lines, adoptJSONLine(item))
		} else {
			lines = append(lines, adoptTextLine(item))
		}
	}
	text := format.JoinLines(lines)

	if refused {
		// The report is the answer and goes to stdout even when the exit code says "not conformant".
		return failWithText(
			text,
			"some skills were refused (an edited block is rewritten only with --force)",
			ExitFailure,
		)
	}
	return OK(text)
}
