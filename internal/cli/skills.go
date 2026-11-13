package cli

import (
	"errors"
	"os"
	"sort"
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
)

// The `skills` verb: `audit`, `adopt`, and `template show|seed|reset`.
//
// The subcommands live under `skills`, split at the sub-verb (not as mode
// flags):
//
//   - `skills audit` — read-only. Classify every skill's fenced usage-log
//     block as `ok`, `missing`, `stale`, `edited` or `vendored`, one line
//     per skill, exit 1 on anything but `ok`/`vendored`. Writes nothing —
//     not even a state directory.
//   - `skills adopt` — write: append a block where there is none, rewrite a
//     `stale` one, rewrite an `edited` one only with `--force`, skip
//     `vendored` skills and leave `ok` ones alone. Every write goes through
//     the document package's splice and the atomic replacement; no byte
//     outside the fence is ever touched. Exit 0 when the directory ends
//     conformant, 1 when any skill is refused.
//   - `skills template show|seed|reset` — the two shipped default templates
//     and the user's copies of them. `show` reports the effective templates,
//     their source, hashes and whether the shipped default moved since the
//     copy was seeded. `seed` copies the shipped defaults into the user
//     directory. `reset` deletes the user copies. Both refuse without
//     `--force` and both support `--dry-run`.
//
// ## The templates
//
// Two shipped defaults, embedded in the binary, resolved over the user's
// copies:
//
//  1. `--template-dir <dir>`
//  2. `SKILL_LOG_TEMPLATE_DIR`
//  3. `${XDG_CONFIG_HOME:-$HOME/.config}/skill-log/templates/`
//  4. the shipped default in the binary
//
// The effective template is the first source that has the file. Its hash is
// the hash of its own bytes (the fence records that hash). The seeded-from
// record — the hash of the shipped default each user copy was seeded from —
// lives under XDG state, never under the user config dir, so `show` and
// `audit` can report `moved` by comparing it to the current shipped default.
// A moved default is *reported* with the two commands that adopt it (`skills
// template seed --force`, then `skills adopt`) and never applied.
//
// ## The vendored stamp
//
// A skill whose frontmatter carries `metadata:` with a `source:` key is a
// copy of someone else's skill and is skipped entirely (SPEC §7); see
// document.IsVendored.

// The state directory that records the seeded-from hash of each user copy. It
// is under XDG state — never under the user config dir — so a tool that reads
// the config dir never trips over it.
const seededDirName = "seeded-from"

// The five actions `adopt` reports, exactly the SPEC §5.10 vocabulary.
const (
	actionAppended  = "appended"
	actionRewritten = "rewritten"
	actionUnchanged = "unchanged"
	actionRefused   = "refused"
	actionSkipped   = "skipped"
)

// The actions `template seed` and `template reset` report, exactly the
// SPEC §5.10 vocabulary. One action per template, so a caller reads a value
// and never matches prose:
//
//	seeded       — the shipped default was copied into the user directory
//	would_seed   — a dry run: the copy would be written, and nothing was
//	refused      — a copy is already there and `--force` was not given
//	deleted      — the user copy was removed
//	would_delete — a dry run: the copy would be removed, and nothing was
//	absent       — there was no user copy to remove
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
		Name: "skills",
		// One renderer, one spelling. The Mojo tree carried this prose twice,
		// with a comma in the verb's own block that the verb table did not
		// have; here the summary is the verb table's, so the two places the
		// prose appears agree.
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
		// The flags that consume the next argument. The dispatcher reads this
		// to tell `--dir --help` (a directory named `--help`) from a help
		// request.
		ValueFlags: []string{"--dir", "--template-dir"},
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
		// The verb owns its own help: `skills --help` prints the verb block,
		// `skills audit --help` the audit block. The dispatcher hands the
		// arguments to the handler instead of answering the help request
		// itself.
		NestedHelp: true,
		Handle:     handleSkills,
	}
}

func init() { register(skillsVerb()) }

// parseSkillsOptions reads `skills`'s subcommand and its flags.
//
// The first positional is the subcommand (`audit`, `template`, `adopt`);
// `template` takes a second positional (`show`, `seed`, `reset`). An unknown
// flag or a missing value is a usage error, raised as a usage marker the
// caller turns into exit 2.
func parseSkillsOptions(args []string) (skillsOptions, error) {
	var options skillsOptions
	var positionals []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--dir":
			value, err := takeValue(args, i, "--dir", "a path")
			if err != nil {
				return options, err
			}
			options.dir = value
			i++
		case "--template-dir":
			value, err := takeValue(args, i, "--template-dir", "a path")
			if err != nil {
				return options, err
			}
			options.templateDir = value
			i++
		case "--json":
			options.json = true
		case "--dry-run":
			options.dryRun = true
		case "--force":
			options.force = true
		default:
			if strings.HasPrefix(arg, "--") {
				return options, usageError{"unknown option: " + arg}
			}
			positionals = append(positionals, arg)
		}
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

// skillTemplate is one effective template: its bytes, its source, its hash.
type skillTemplate struct {
	name    string
	content string
	source  string
	hash    string
	moved   bool
}

// loadTemplate returns the effective template name, resolved over the shipped
// default.
//
// The source is the first of the chain that has the file: the resolved
// directory, then the shipped default embedded in the binary. The hash is of
// the effective bytes. `moved` is set when the file came from the user
// directory and the shipped default's hash differs from the seeded-from hash
// on record — that is the "the shipped default moved since this copy was
// seeded" report.
func loadTemplate(name, templateDir string) (skillTemplate, error) {
	out := skillTemplate{name: name, source: "shipped"}
	// The directory is checked before the path is built: an empty directory
	// has no file to name, and joining onto it would spell a path at the
	// filesystem root.
	if templateDir != "" {
		candidate := joinPath(templateDir, name)
		if format.IsRegularFile(candidate) {
			content, err := format.ReadText(candidate)
			if err != nil {
				return out, errors.New("cannot read template " + candidate + ": " + err.Error())
			}
			out.content = content
			out.source = candidate
		}
	}
	if out.source == "shipped" {
		content, err := assets.Shipped(name)
		if err != nil {
			return out, err
		}
		out.content = content
	}
	out.hash = document.Hash(out.content)

	// A user copy's provenance: compare the shipped default's current hash to
	// the hash the copy was seeded from. Only a user copy has a seeded-from
	// record to compare against; a shipped default cannot have "moved" from
	// itself.
	if out.source != "shipped" {
		seeded := readSeeded(name)
		if seeded != "" {
			shipped, err := assets.Shipped(name)
			if err != nil {
				return out, err
			}
			out.moved = seeded != document.Hash(shipped)
		}
	}
	return out, nil
}

// movedDefaultNote is the one line that names a moved shipped default, or "".
//
// SPEC §7: a shipped default that moved since the user copy was seeded is
// named, with the two commands that adopt it — seed the new default over the
// old copy, then re-render every block. Only a human runs those, and only to
// discard their own wording.
//
// The line is one line, because the failure it belongs to gets exactly one
// stderr line (SPEC §2).
func movedDefaultNote(usage, review skillTemplate) string {
	if !usage.moved && !review.moved {
		return ""
	}
	return "the shipped default moved; adopt it with" +
		" 'skill-log skills template seed --force'," +
		" then 'skill-log skills adopt --dir <dir>'"
}

// movedSuffix is the moved-default clause to append to another message, or "".
//
// The failure gets exactly one stderr line (SPEC §2), so a moved default that
// rides along with another failure is a clause of that line, not a line of
// its own.
func movedSuffix(moved string) string {
	if moved == "" {
		return ""
	}
	return "; " + moved
}

// validateEffective refuses a template whose placeholders are wrong, by name.
//
// This is the boundary guard SPEC §7 names: a usage-log template that lost
// its `<name>` or its `<command> add` invocation would silently stop every
// skill from logging, so it is refused before it renders.
func validateEffective(name string, template skillTemplate) error {
	return document.ValidateTemplate(name, template.content)
}

// resolveTemplateDir returns the effective template directory, by the spec's
// chain.
//
// `--template-dir` first, then `SKILL_LOG_TEMPLATE_DIR`, then the user config
// directory. The shipped defaults are a separate fallback: a directory that
// does not contain a given template name falls through to the shipped default
// for that name.
func resolveTemplateDir(flag string) string {
	if strings.TrimSpace(flag) != "" {
		return strings.TrimSpace(flag)
	}
	if env := settings.EnvOrEmpty("SKILL_LOG_TEMPLATE_DIR"); strings.TrimSpace(env) != "" {
		return strings.TrimSpace(env)
	}
	return settings.TemplatesDir()
}

// seededPath is where the seeded-from record for template name lives (XDG
// state).
func seededPath(name string) string {
	return joinPath(joinPath(settings.StateDir(), seededDirName), name)
}

// readSeeded returns the seeded-from hash of the user's name copy, or "".
//
// The record is a single line: the hash of the shipped default the copy was
// seeded from. A missing record means the copy predates the record (or was
// never seeded here) — reported as unknown, not moved.
func readSeeded(name string) string {
	path := seededPath(name)
	if !format.IsRegularFile(path) {
		return ""
	}
	text, err := format.ReadText(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(text)
}

// writeSeeded records the seeded-from hash for template name under XDG state.
func writeSeeded(name, hashValue string) error {
	dir := joinPath(settings.StateDir(), seededDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return format.WriteText(seededPath(name), hashValue+"\n")
}

// clearSeeded removes the seeded-from record for template name (as `reset`).
func clearSeeded(name string) {
	path := seededPath(name)
	if format.IsRegularFile(path) {
		_ = os.Remove(path)
	}
}

// findInPath returns program as the first executable name on PATH, or
// unchanged.
//
// The shell's own first-match rule, for when the tool is invoked by bare name:
// PATH is walked left to right and the first entry that holds the file wins. A
// name PATH does not carry comes back as it went in — the caller still
// resolves it, and still falls back to the given name.
func findInPath(program string) string {
	path := settings.EnvOrEmpty("PATH")
	start := 0
	n := len(path)
	for start <= n {
		cut := strings.Index(path[start:], ":")
		if cut < 0 {
			cut = n
		} else {
			cut = start + cut
		}
		entry := path[start:cut]
		if entry != "" {
			candidate := entry + "/" + program
			if format.IsRegularFile(candidate) {
				return candidate
			}
		}
		start = cut + 1
	}
	return program
}

// resolvedCommand returns the path of this binary, resolved: `<command>`'s
// value.
//
// "The resolved binary path" is one answer no matter how the tool was
// invoked: a bare name is looked up on PATH, and whatever is found — or given
// — is resolved to one absolute, symlink-free path. A name the filesystem
// cannot resolve (a deleted binary, say) is used as it was given rather than
// dropped.
func resolvedCommand() string {
	program := os.Args[0]
	if !strings.Contains(program, "/") {
		program = findInPath(program)
	}
	if real := format.ResolvePath(program); real != "" {
		return real
	}
	return program
}

// joinPath is the tool's path spelling: the directory and the name joined
// with a separator, exactly as the caller wrote the directory.
//
// The join is deliberately naive rather than filepath.Join's cleaning one:
// the path a skill is reported under is the caller's own `--dir` with the
// skill's directory name appended, so `--dir skills/` reports `skills//x`
// and `--dir ./skills` reports `./skills/x`. Cleaning the spelling would
// change what the report says about a path the caller chose.
func joinPath(dir, name string) string { return dir + "/" + name }

// skillDirs returns the skill subdirectories of dir: those holding a
// `SKILL.md`.
//
// A skill is a subdirectory of `--dir` with a `SKILL.md` in it. The names come
// back sorted so the report is deterministic. A directory that does not exist
// is an empty list; the caller decides what an empty answer means (audit
// refuses one).
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
// The current render is the one this skill would get now: the template
// rendered for *this* skill's name and the resolved binary path. A block that
// names a different skill or a different binary is an older render, and the
// skill is `stale` — not `ok`.
//
// The name is the skill's frontmatter `name:`, else the directory name it is
// called by everywhere else: the same name `adopt` renders for.
func auditSkill(dir, name string, template skillTemplate, command string) (skillState, error) {
	result := skillState{skill: name, path: joinPath(dir, name)}
	docPath := joinPath(result.path, "SKILL.md")
	text, err := format.ReadText(docPath)
	if err != nil {
		return result, errors.New("cannot read " + docPath + ": " + err.Error())
	}
	skillName := document.FrontmatterName(text)
	if skillName == "" {
		skillName = name
	}
	rendered := document.Render(template.content, skillName, command)
	// The document package owns the classification; the audit only names the
	// skill it came from. IsVendored short-circuits inside Classify, which
	// is where the vendor stamp is decided.
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
// The state is the document's state *before* the run (the same answer `audit`
// gives), and the action is what this run did with it: `missing` is appended
// to, `stale` rewritten, `edited` rewritten only with `--force` and otherwise
// refused, `ok` is left `unchanged`, and `vendored` is `skipped` entirely.
//
// The write is the document package's splice — Append or Rewrite — through
// the atomic replacement, so no byte outside the fence can change and no
// half-written file is ever visible. A dry run reports the same actions and
// writes nothing.
func adoptSkill(dir, name string, template skillTemplate, command string, force, dryRun bool) (adopted, error) {
	result := adopted{skill: name, path: joinPath(dir, name)}
	docPath := joinPath(result.path, "SKILL.md")
	text, err := format.ReadText(docPath)
	if err != nil {
		return result, errors.New("cannot read " + docPath + ": " + err.Error())
	}

	// The rendered block names the skill: `name:` from its frontmatter, else
	// the directory name it is called by everywhere else.
	skillName := document.FrontmatterName(text)
	if skillName == "" {
		skillName = name
	}
	rendered := document.Render(template.content, skillName, command)
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

// auditJSONLine is one audit object, exactly `skill`, `path`, `state`
// (SPEC §5.10).
func auditJSONLine(item skillState) string {
	return "{" +
		`"skill":` + format.JSONString(item.skill) +
		`,"path":` + format.JSONString(item.path) +
		`,"state":` + format.JSONString(item.state) +
		"}"
}

// auditTextLine is one audit line for a person: the state, the skill, the path.
func auditTextLine(item skillState) string {
	return item.state + "  " + item.skill + "  " + item.path
}

// adoptJSONLine is one adopt object, exactly `skill`, `path`, `state`,
// `action` (SPEC §5.10).
func adoptJSONLine(item adopted) string {
	return "{" +
		`"skill":` + format.JSONString(item.skill) +
		`,"path":` + format.JSONString(item.path) +
		`,"state":` + format.JSONString(item.state) +
		`,"action":` + format.JSONString(item.action) +
		"}"
}

// adoptTextLine is one adopt line for a person: the action, the state, the
// skill.
func adoptTextLine(item adopted) string {
	return item.action + "  " + item.state + "  " + item.skill + "  " + item.path
}

// templateJSON is one template object, per SPEC §5.10's `skills template show`.
func templateJSON(t skillTemplate) string {
	return "{" +
		`"name":` + format.JSONString(t.name) +
		`,"source":` + format.JSONString(t.source) +
		`,"content":` + format.JSONString(t.content) +
		`,"template_hash":` + format.JSONString(t.hash) +
		`,"content_hash":` + format.JSONString(t.hash) +
		`,"moved":` + format.JSONBool(t.moved) +
		"}"
}

// templateAction is one template's outcome under `seed` or `reset`.
//
// The path is the file the action is about, and the action is one of the
// fixed tokens above. The human line is prose; the JSON carries the two
// values.
type templateAction struct {
	path   string
	action string
	note   string
}

// templateActionJSON is one action object, exactly `path`, `action`
// (SPEC §5.10).
func templateActionJSON(item templateAction) string {
	return "{" +
		`"path":` + format.JSONString(item.path) +
		`,"action":` + format.JSONString(item.action) +
		"}"
}

// subcommandHelp is the usage block for one `skills` subcommand.
//
// Each nesting level's help ends with two to four real invocations, as the
// common rules require. The block is the subcommand's own: what it does, how
// to call it, and copy-pasteable examples.
func subcommandHelp(sub string) string {
	switch sub {
	case "audit":
		return "skills audit — classify every skill's usage-log block\n" +
			"\nusage:\n" +
			"  skill-log skills audit --dir <dir> [--json] [--dry-run]\n" +
			"\n" +
			"One line per skill, and exit 1 on any state but ok or\n" +
			"vendored. Read-only: it writes nothing, not even a state\n" +
			"directory. An empty directory is refused.\n" +
			"\n" +
			"ok means the block is the current render: the same template,\n" +
			"for that skill's name and the resolved binary path. A moved\n" +
			"binary or a renamed skill makes the block an older render,\n" +
			"and the skill is stale.\n" +
			"\nexamples:\n" +
			"  skill-log skills audit --dir .agents/skills\n" +
			"  skill-log skills audit --dir .agents/skills --json\n" +
			"  skill-log skills audit --dir .agents/skills --dry-run\n"
	case "adopt":
		return "skills adopt — make a repo's skills conform\n" +
			"\nusage:\n" +
			"  skill-log skills adopt --dir <dir> [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Appends a fenced block where there is none, rewrites a block\n" +
			"whose content is an older render, and rewrites a hand-edited\n" +
			"block only with --force. A vendored skill is skipped entirely.\n" +
			"Not one byte outside the fence is rewritten or removed —\n" +
			"unfenced text is never touched, not even with --force. A\n" +
			"second run changes nothing.\n" +
			"\n" +
			"One line per skill: the action (appended, rewritten,\n" +
			"unchanged, refused, skipped), the state it was in, the skill\n" +
			"and its path. --json emits the same as one object per skill.\n" +
			"--dry-run prints the same answer and writes nothing.\n" +
			"\n" +
			"Exits 0 when the directory ends conformant, 1 when any skill\n" +
			"is refused — an edited block left untouched without --force.\n" +
			"A directory that holds no skills is refused.\n" +
			"\nexamples:\n" +
			"  skill-log skills adopt --dir .agents/skills\n" +
			"  skill-log skills adopt --dir .agents/skills --force\n" +
			"  skill-log skills adopt --dir .agents/skills --dry-run --json\n"
	case "template show":
		return "skills template show — the effective templates and their provenance\n" +
			"\nusage:\n" +
			"  skill-log skills template show [--json] [--template-dir <dir>]\n" +
			"\n" +
			"Prints both effective templates, their source, their hashes,\n" +
			"and whether the shipped default has moved since the user copy\n" +
			"was seeded. The usage-log template is also the pasteable\n" +
			"snippet. A moved default is reported with the two commands\n" +
			"that adopt it and never applied.\n" +
			"\nexamples:\n" +
			"  skill-log skills template show\n" +
			"  skill-log skills template show --json\n" +
			"  skill-log skills template show --template-dir ./my-templates\n"
	case "template seed":
		return "skills template seed — copy the shipped defaults into the user directory\n" +
			"\nusage:\n" +
			"  skill-log skills template seed [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Copies the two shipped defaults into\n" +
			"${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/. Without\n" +
			"--force it refuses to overwrite an existing copy.\n" +
			"\n" +
			"--json emits one object per template: the path and the\n" +
			"action, which is one of seeded, would_seed (a dry run) or\n" +
			"refused (a copy is already there).\n" +
			"\nexamples:\n" +
			"  skill-log skills template seed\n" +
			"  skill-log skills template seed --force\n" +
			"  skill-log skills template seed --force --dry-run\n"
	case "template reset":
		return "skills template reset — delete the user copies, back to the shipped defaults\n" +
			"\nusage:\n" +
			"  skill-log skills template reset [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Deletes the user copies and returns to the shipped defaults,\n" +
			"which the next adopt re-renders. It refuses while copies\n" +
			"exist unless --force is given.\n" +
			"\n" +
			"--json emits one object per template: the path and the\n" +
			"action, which is one of deleted, would_delete (a dry run),\n" +
			"absent (there was no copy) or refused (copies are there).\n" +
			"\nexamples:\n" +
			"  skill-log skills template reset --force\n" +
			"  skill-log skills template reset --force --dry-run\n" +
			"  skill-log skills template reset\n"
	case "template":
		return "skills template — the two shipped usage-log templates\n" +
			"\nusage:\n" +
			"  skill-log skills template show [--json] [--template-dir <dir>]\n" +
			"  skill-log skills template seed [--force] [--dry-run] [--json]\n" +
			"  skill-log skills template reset [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Subcommands, not mode flags: show reports, seed copies the\n" +
			"shipped defaults into the user directory, reset deletes them\n" +
			"back to the shipped defaults. The templates resolve by\n" +
			"--template-dir, then SKILL_LOG_TEMPLATE_DIR, then\n" +
			"${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/, then the\n" +
			"shipped default in the binary.\n" +
			"\n" +
			"seed and reset emit one JSON object per template -- the path\n" +
			"and the action -- so a caller reads a value and never\n" +
			"matches prose.\n" +
			"\nexamples:\n" +
			"  skill-log skills template show\n" +
			"  skill-log skills template seed --force\n" +
			"  skill-log skills template reset --force\n"
	}
	return ""
}

// handleSkills is the `skills` handler: dispatch on the subcommand.
//
// It never prints and never exits: the CLI boundary owns both.
//
// A `--help` or `-h` anywhere in the call is a request for the subcommand's
// own help: `skills audit --help` prints the audit block, `skills template
// show --help` the show block, and `skills --help` the whole verb block. The
// subcommand is read from the first positional, so the help target is known
// before flags are parsed.
func handleSkills(args []string) Outcome {
	// Find the subcommand and whether help was asked for, without parsing
	// values: a bare scan, so `--dir --help` still treats `--help` as a value
	// of `--dir` only when it follows it. The verb's value flags are the ones
	// the dispatcher already knows, so the same step-over rule applies here.
	wantsHelp := false
	var positionals []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--help" || arg == "-h":
			wantsHelp = true
		case arg == "--dir" || arg == "--template-dir":
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
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
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

// failWithText fails with message and exit code, but still prints text on
// stdout: the findings are the answer, and the exit code says the answer is
// "not clean".
func failWithText(text, message string, code int) Outcome {
	outcome := Fail(message, code)
	outcome.Text = text
	return outcome
}

// handleAudit is `skills audit`: one line per skill, exit 1 on anything but
// ok/vendored, and writes nothing.
func handleAudit(options skillsOptions) Outcome {
	if strings.TrimSpace(options.dir) == "" {
		return Fail("usage: skills audit needs --dir <dir>", ExitUsage)
	}
	dir := strings.TrimSpace(options.dir)

	// The current render is what the fence is compared against. The effective
	// template is validated first: a broken template must not silently mark
	// every skill stale.
	templateDir := resolveTemplateDir(options.templateDir)
	template, err := loadTemplate(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	review, err := loadTemplate(assets.ReviewName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := validateEffective(assets.UsageLogName, template); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	// A shipped default that moved since the user copy was seeded is named
	// here too (SPEC §7): the blocks are rendered from the old default, so
	// the whole directory is behind — and only a human can decide to discard
	// their own wording.
	moved := movedDefaultNote(template, review)

	// The resolved binary path is the other half of the current render: the
	// block names it, so a binary that moved makes every block an older
	// render.
	command := resolvedCommand()
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
		// The findings are the answer and go to stdout even when the exit
		// code says "not clean"; the summary is the one stderr line the
		// failure is allowed.
		return failWithText(
			text,
			"some skills need adoption"+movedSuffix(moved),
			ExitFailure,
		)
	}
	if moved != "" {
		// A moved default is its own failure: the directory may be clean, and
		// it is still behind the shipped default.
		return failWithText(text, moved, ExitFailure)
	}
	return OK(text)
}

// handleAdopt is `skills adopt`: make every skill in `--dir` conform.
//
// One line (or object) per skill, exit 0 when the directory ends conformant,
// exit 1 when any skill is refused — an `edited` block left untouched because
// `--force` was not given. `--dry-run` prints the same answer and writes
// nothing.
func handleAdopt(options skillsOptions) Outcome {
	if strings.TrimSpace(options.dir) == "" {
		return Fail("usage: skills adopt needs --dir <dir>", ExitUsage)
	}
	dir := strings.TrimSpace(options.dir)

	// The effective template is validated first: rendering from a broken
	// template would write blocks no skill can log from.
	templateDir := resolveTemplateDir(options.templateDir)
	template, err := loadTemplate(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := validateEffective(assets.UsageLogName, template); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	command := resolvedCommand()
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
		// The report is the answer and goes to stdout even when the exit code
		// says "not conformant"; the summary is the one stderr line the
		// failure is allowed.
		return failWithText(
			text,
			"some skills were refused (an edited block is rewritten only with --force)",
			ExitFailure,
		)
	}
	return OK(text)
}

// handleTemplateShow is `skills template show`: both effective templates,
// their source, hashes, and whether the shipped default has moved.
func handleTemplateShow(options skillsOptions) Outcome {
	templateDir := resolveTemplateDir(options.templateDir)
	usage, err := loadTemplate(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	review, err := loadTemplate(assets.ReviewName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := validateEffective(assets.UsageLogName, usage); err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := validateEffective(assets.ReviewName, review); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	if options.json {
		out := `{"templates":[` + templateJSON(usage) + "," + templateJSON(review) + "]}"
		return OK(out)
	}

	var text strings.Builder
	text.WriteString("usage-log.md\n")
	text.WriteString("  source: " + usage.source + "\n")
	text.WriteString("  template_hash: " + usage.hash + "\n")
	text.WriteString("  content_hash: " + usage.hash + "\n")
	text.WriteString("  moved: " + format.JSONBool(usage.moved) + "\n")
	text.WriteString("\nskill-friction-review.md\n")
	text.WriteString("  source: " + review.source + "\n")
	text.WriteString("  template_hash: " + review.hash + "\n")
	text.WriteString("  content_hash: " + review.hash + "\n")
	text.WriteString("  moved: " + format.JSONBool(review.moved) + "\n")
	if usage.moved || review.moved {
		text.WriteString(
			"\nthe shipped default moved; adopt it with:\n" +
				"  skill-log skills template seed --force\n" +
				"  skill-log skills adopt --dir <dir>\n",
		)
	}
	text.WriteString("\nusage-log snippet (paste into a skill):\n")
	text.WriteString(usage.content + "\n")
	return OK(text.String())
}

// handleTemplateSeed is `skills template seed`: copy the shipped defaults
// into the user directory, refusing an existing copy without `--force`.
//
// One action per template. The action is a fixed token, so the JSON carries
// the same fact the human line does; `--dry-run` previews the same shape and
// writes nothing.
func handleTemplateSeed(options skillsOptions) Outcome {
	dir := settings.TemplatesDir()
	names := assets.Names()
	var actions []templateAction
	refused := false

	for _, name := range names {
		target := joinPath(dir, name)
		if format.IsRegularFile(target) && !options.force {
			refused = true
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionRefused,
				note:   name + ": refused (exists; use --force)",
			})
			continue
		}
		content, err := assets.Shipped(name)
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		if options.dryRun {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionWouldSeed,
				note:   name + ": would write " + target,
			})
			continue
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return Fail("cannot create "+dir+": "+err.Error(), ExitFailure)
		}
		if err := format.WriteText(target, content); err != nil {
			return Fail("cannot write "+target+": "+err.Error(), ExitFailure)
		}
		if err := writeSeeded(name, document.Hash(content)); err != nil {
			return Fail("cannot write "+seededPath(name)+": "+err.Error(), ExitFailure)
		}
		actions = append(actions, templateAction{
			path:   target,
			action: templateActionSeeded,
			note:   name + ": wrote " + target,
		})
	}

	var lines []string
	for _, action := range actions {
		if options.json {
			lines = append(lines, templateActionJSON(action))
		} else {
			lines = append(lines, action.note)
		}
	}
	text := format.JoinLines(lines)

	if refused {
		return failWithText(text, "seed refused an existing copy", ExitFailure)
	}
	return OK(text)
}

// handleTemplateReset is `skills template reset`: delete the user copies back
// to the shipped defaults, refusing while copies exist without `--force`.
//
// One action per template, with the same fixed tokens `seed` uses: a copy
// that is not there is `absent`, not a deletion.
func handleTemplateReset(options skillsOptions) Outcome {
	dir := settings.TemplatesDir()
	names := assets.Names()
	var actions []templateAction
	refused := false

	for _, name := range names {
		target := joinPath(dir, name)
		if !format.IsRegularFile(target) {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionAbsent,
				note:   name + ": absent",
			})
			continue
		}
		if !options.force {
			refused = true
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionRefused,
				note:   name + ": refused (exists; use --force)",
			})
			continue
		}
		if options.dryRun {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionWouldDelete,
				note:   name + ": would delete " + target,
			})
			continue
		}
		if err := os.Remove(target); err != nil {
			return Fail("cannot remove "+target+": "+err.Error(), ExitFailure)
		}
		actions = append(actions, templateAction{
			path:   target,
			action: templateActionDeleted,
			note:   name + ": deleted " + target,
		})
	}

	if options.force && !options.dryRun {
		for _, name := range names {
			clearSeeded(name)
		}
	}

	var lines []string
	for _, action := range actions {
		if options.json {
			lines = append(lines, templateActionJSON(action))
		} else {
			lines = append(lines, action.note)
		}
	}
	text := format.JoinLines(lines)

	if refused {
		return failWithText(text, "reset refused while copies exist", ExitFailure)
	}
	return OK(text)
}

// isFile reports whether path is a regular file.
