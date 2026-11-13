package cli

import (
	"os"
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
	templatepkg "github.com/Dahep/skill-log/internal/template"
)

// The ownership marker every generated hook carries, on a line of its own.
// It is the one thing that says "this tool wrote this file": without it a
// `post-merge` is never replaced or removed.
const hookMarker = "# skill-log:post-merge-hook"

// The hook's name inside the repository's common hooks directory.
const hookName = "post-merge"

// The mode the generated hook is written with: git runs a hook only when it
// is executable, so the file carries its execute bits at creation and no
// umask can narrow them.
const hookMode = 0o755

// The artifact names, in the order every output lists them.
const (
	artifactStore     = "store"
	artifactHook      = "hook"
	artifactReportDir = "report_dir"
	artifactSkills    = "skills"
)

// The verdict statuses. `drift` is the one that fails the run: under
// `--check` it means "not set up", otherwise it means "this run refused to
// change it".
const (
	statusCreated   = "created"
	statusUpdated   = "updated"
	statusUnchanged = "unchanged"
	statusDrift     = "drift"
	statusSkipped   = "skipped"
)

// setupOptions is the flags `setup` accepts.
type setupOptions struct {
	repo        string
	skillsDir   string
	db          string
	json        bool
	dryRun      bool
	check       bool
	force       bool
	removeHook  bool
	noHook      bool
	noReportDir bool
}

func setupVerb() Verb {
	return Verb{
		Name:    "setup",
		Summary: "make a machine and a repo ready: store, hook, report directory",
		Usage: "skill-log setup [--repo <dir>] [--skills-dir <dir>] [--db <path>]\n" +
			"                [--check] [--dry-run] [--json] [--force]\n" +
			"                [--remove-hook] [--no-hook] [--no-report-dir]",
		Examples: []string{
			"skill-log setup",
			"skill-log setup --repo ~/src/myrepo --check",
			"skill-log setup --dry-run --json",
			"skill-log setup --remove-hook",
		},
		// The flags that consume the next argument: the dispatcher reads this
		// to tell `--repo --help` from a help request.
		ValueFlags: setupFlags(&setupOptions{}).names(),
		Notes: "One command makes a machine and a repo ready: the store, the git\n" +
			"post-merge hook that resolves what a pull landed, the report\n" +
			"directory (.skill-log/reports/ with its README and keep file),\n" +
			"and the two bundled skills under --skills-dir. It prints the\n" +
			"machine identity the log will use, so the spelling every marker\n" +
			"must match is visible. Re-running is a no-op.\n" +
			"\n" +
			"The hook goes only into the repository's common hooks directory\n" +
			"(git rev-parse --git-common-dir), so a linked worktree shares one\n" +
			"hook. A post-merge without the ownership marker is refused by\n" +
			"name and never overwritten; --remove-hook removes only a marked\n" +
			"hook. The hook resolves the CLI at run time and never changes a\n" +
			"pull's exit status.\n" +
			"\n" +
			"--skills-dir installs the two bundled skills: skill-log (the\n" +
			"read-and-report skill, copied verbatim with a version stamp that\n" +
			"is its only provenance) and skill-friction-review (rendered from\n" +
			"the skill-friction-review.md template with the resolved binary\n" +
			"path, followed by its own usage-log block). Both audit ok on the\n" +
			"next skills audit. A differing copy is left alone and named\n" +
			"unless --force replaces it; customising the review skill means\n" +
			"editing the template, not the installed file.\n" +
			"\n" +
			"--check verifies the store, the hook, the report directory and\n" +
			"the installed skills instead of writing, and exits 1 on drift —\n" +
			"a missing skill, a stale or stripped version stamp, or a\n" +
			"differing copy. --dry-run shows what a real run would change. A\n" +
			"store written by another schema is named and left alone: setup\n" +
			"creates a store and never migrates one.\n" +
			"\n" +
			"--no-hook and --no-report-dir turn one artifact off. A directory\n" +
			"that is not a git checkout is skipped with a named reason,\n" +
			"exit 0.",
		Handle: handleSetup,
	}
}

func init() { register(setupVerb()) }

// setupFlags reads `setup`'s flags.
func setupFlags(options *setupOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--repo", "a directory", func(value string) error { options.repo = value; return nil })
	flags.value("--skills-dir", "a directory", func(value string) error { options.skillsDir = value; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	return flags
}

func parseSetupOptions(args []string) (setupOptions, error) {
	var options setupOptions
	flags := setupFlags(&options)
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--check", func() error { options.check = true; return nil })
	flags.switchFlag("--force", func() error { options.force = true; return nil })
	flags.switchFlag("--remove-hook", func() error { options.removeHook = true; return nil })
	flags.switchFlag("--no-hook", func() error { options.noHook = true; return nil })
	flags.switchFlag("--no-report-dir", func() error { options.noReportDir = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
	}
	// Two modes that say opposite things about the hook cannot be one run.
	// The pair is refused before anything is examined.
	if options.check && options.removeHook {
		return options, usageError{"--check verifies and --remove-hook removes; pick one"}
	}
	if options.removeHook && options.noHook {
		return options, usageError{"--remove-hook and --no-hook cannot be combined"}
	}
	return options, nil
}

// hookScript is the post-merge hook `setup` writes.
//
// It resolves the CLI at run time — `command -v skill-log`, then
// `mise which skill-log` when mise is on `PATH`, then the mise shim under
// `$HOME`, then nothing (exit 0 silently) — derives the pre-merge position
// from the reflog, and calls `resolve-merged` quietly. Every failure is
// swallowed: a pull's exit status is git's alone.
func hookScript() string {
	return `#!/bin/sh
# skill-log:post-merge-hook
#
# Installed by skill-log setup; removed by skill-log setup --remove-hook.
# Resolves the rows a pull landed. It never changes the pull's exit
# status: a missing, older or failing skill-log is skipped silently, and
# nothing here writes to stderr.

cli=
if command -v skill-log >/dev/null 2>&1; then
    cli=$(command -v skill-log)
fi
if [ -z "$cli" ] && command -v mise >/dev/null 2>&1; then
    cli=$(mise which skill-log 2>/dev/null)
fi
if [ -z "$cli" ] && [ -x "$HOME/.local/share/mise/shims/skill-log" ]; then
    cli="$HOME/.local/share/mise/shims/skill-log"
fi
[ -n "$cli" ] || exit 0

since=$(git rev-parse --verify -q 'HEAD@{1}' 2>/dev/null)
if [ -n "$since" ]; then
    "$cli" resolve-merged --since "$since" --quiet >/dev/null 2>&1
else
    "$cli" resolve-merged --quiet >/dev/null 2>&1
fi

exit 0
`
}

// hasOwnershipMarker reports whether text carries the ownership marker at a
// line start.
//
// The marker is a comment line, so prose that merely mentions it still
// counts as carrying it — the marker's job is to say who wrote the file, and
// an edited copy of our own hook is still ours to replace.
func hasOwnershipMarker(text string) bool {
	n := len(text)
	start := 0
	for start <= n {
		if strings.HasPrefix(text[start:], hookMarker) {
			return true
		}
		end := strings.Index(text[start:], "\n")
		if end < 0 {
			return false
		}
		start = start + end + 1
	}
	return false
}

// verdict is one artifact's verdict: its name, what happened, and why.
type verdict struct {
	artifact string
	status   string
	detail   string
}

// verdictLine is one human line: the status, the artifact, the detail.
func verdictLine(v verdict) string {
	return v.status + "  " + v.artifact + "  " + v.detail
}

// verdictJSON is one JSON object, exactly `artifact`, `status`, `detail`.
func verdictJSON(v verdict) string {
	return format.Object(
		format.Str("artifact", v.artifact),
		format.Str("status", v.status),
		format.Str("detail", v.detail),
	)
}

// storeVerdict is the store's verdict: `create`, or `verify` under `--check`.
//
// The verdict comes from the store's own path — the verify policy for the
// read and the create policy for the creation — and never from inspecting
// SQLite here. A refused store is drift with the refusal's own named
// message: setup creates a store and never migrates one.
func storeVerdict(path string, check, dryRun bool) verdict {
	opened, failure := openStore(path, false)
	if failure != nil {
		return verdict{artifactStore, statusDrift, failure.Message}
	}
	if opened != nil {
		opened.Close()
		return verdict{artifactStore, statusUnchanged, path}
	}
	if check {
		return verdict{artifactStore, statusDrift, "no store at " + path}
	}
	if dryRun {
		return verdict{artifactStore, statusCreated, path}
	}
	opened, failure = openStore(path, true)
	if failure != nil {
		return verdict{artifactStore, statusDrift, failure.Message}
	}
	if opened != nil {
		opened.Close()
	}
	return verdict{artifactStore, statusCreated, path}
}

// hookVerdict is the post-merge hook's verdict in the common hooks directory —
// where git runs hooks for every checkout of the repository, never a linked
// worktree's own directory.
func hookVerdict(common string, options setupOptions) verdict {
	if common == "" {
		return verdict{artifactHook, statusSkipped, "not a git checkout"}
	}
	if options.removeHook {
		return removeHookVerdict(hookPath(common), options.dryRun)
	}
	if options.noHook {
		return verdict{artifactHook, statusSkipped, "hook disabled by --no-hook"}
	}

	path := hookPath(common)
	wanted := hookScript()
	if format.IsRegularFile(path) {
		text, err := format.ReadText(path)
		if err != nil {
			return verdict{artifactHook, statusDrift, err.Error()}
		}
		if !hasOwnershipMarker(text) {
			// Never overwrite a file this tool did not write: the marker is
			// the ownership claim, and without it the file is refused by
			// name.
			return verdict{
				artifactHook,
				statusDrift,
				"the post-merge hook at " + path + " carries no ownership marker",
			}
		}
		if text == wanted {
			// The bytes are right, but git runs a hook only when it is
			// executable — and it says nothing when it is not, so the merged
			// reports would stop resolving silently.
			if !format.IsExecutable(path) {
				if options.check {
					return verdict{
						artifactHook,
						statusDrift,
						"the post-merge hook at " + path +
							" is not executable (git skips a hook it" +
							" cannot run)",
					}
				}
				if options.dryRun {
					return verdict{
						artifactHook,
						statusUpdated,
						"would make " + path + " executable",
					}
				}
				if err := format.SetExecutable(path); err != nil {
					return verdict{artifactHook, statusDrift, err.Error()}
				}
				return verdict{
					artifactHook,
					statusUpdated,
					"made " + path + " executable",
				}
			}
			return verdict{artifactHook, statusUnchanged, path}
		}
		if options.check {
			return verdict{
				artifactHook,
				statusDrift,
				"the post-merge hook at " + path + " differs from this version's hook",
			}
		}
		if options.dryRun {
			return verdict{artifactHook, statusUpdated, path}
		}
		if err := format.WriteTextMode(path, wanted, hookMode); err != nil {
			return verdict{artifactHook, statusDrift, err.Error()}
		}
		return verdict{artifactHook, statusUpdated, path}
	}

	if options.check {
		return verdict{artifactHook, statusDrift, "no post-merge hook at " + path}
	}
	if options.dryRun {
		return verdict{artifactHook, statusCreated, path}
	}
	if err := os.MkdirAll(joinPath(common, "hooks"), 0o755); err != nil {
		return verdict{artifactHook, statusDrift, err.Error()}
	}
	if err := format.WriteTextMode(path, wanted, hookMode); err != nil {
		return verdict{artifactHook, statusDrift, err.Error()}
	}
	return verdict{artifactHook, statusCreated, path}
}

// hookPath is the hook's path inside the common hooks directory.
func hookPath(common string) string {
	return common + "/hooks/" + hookName
}

// removeHookVerdict is `--remove-hook`: remove the marked hook, and only
// that.
//
// A file without the marker is not ours to remove, so it is left exactly as
// found and named as skipped.
func removeHookVerdict(path string, dryRun bool) verdict {
	if !format.IsRegularFile(path) {
		return verdict{artifactHook, statusUnchanged, "no post-merge hook at " + path}
	}
	text, err := format.ReadText(path)
	if err != nil {
		return verdict{artifactHook, statusDrift, err.Error()}
	}
	if !hasOwnershipMarker(text) {
		return verdict{
			artifactHook,
			statusSkipped,
			"left alone: " + path + " carries no ownership marker",
		}
	}
	if dryRun {
		return verdict{artifactHook, statusUpdated, "removed " + path}
	}
	if err := os.Remove(path); err != nil {
		return verdict{artifactHook, statusDrift, err.Error()}
	}
	return verdict{artifactHook, statusUpdated, "removed " + path}
}

// reportDirVerdict is the report directory's verdict.
//
// The directory is created with its README and keep file and nothing else. A
// file already present is left byte-for-byte alone: the README is the
// operator's to edit and the report files are the transport.
func reportDirVerdict(repo string, options setupOptions) verdict {
	if repo == "" {
		return verdict{artifactReportDir, statusSkipped, "not a git checkout"}
	}
	if options.noReportDir {
		return verdict{
			artifactReportDir,
			statusSkipped,
			"report directory disabled by --no-report-dir",
		}
	}

	dir := repo + "/" + reportDir
	readme := dir + "/" + reportReadmeName
	keep := dir + "/" + reportKeepName

	dirThere := format.IsDir(dir)
	readmeThere := format.IsRegularFile(readme)
	keepThere := format.IsRegularFile(keep)

	if dirThere && readmeThere && keepThere {
		return verdict{artifactReportDir, statusUnchanged, dir}
	}

	if options.check {
		if !dirThere {
			return verdict{artifactReportDir, statusDrift, "no report directory at " + dir}
		}
		if !readmeThere {
			return verdict{artifactReportDir, statusDrift, "no README at " + readme}
		}
		return verdict{artifactReportDir, statusDrift, "no keep file at " + keep}
	}

	status := statusUpdated
	if !dirThere {
		status = statusCreated
	}
	if options.dryRun {
		return verdict{artifactReportDir, status, dir}
	}
	if !dirThere {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return verdict{artifactReportDir, statusDrift, err.Error()}
		}
	}
	if !readmeThere {
		if err := format.WriteText(readme, reportDirReadme()); err != nil {
			return verdict{artifactReportDir, statusDrift, err.Error()}
		}
	}
	if !keepThere {
		if err := format.WriteText(keep, ""); err != nil {
			return verdict{artifactReportDir, statusDrift, err.Error()}
		}
	}
	return verdict{artifactReportDir, status, dir}
}

// skillsVerdict is the installed skills' verdict.
//
// `--skills-dir` installs the two bundled skills and says, per skill, what
// happened. Without it the artifact is skipped with that named reason. Under
// `--check` the same per-skill verdicts are computed with every write turned
// off: anything but this version's exact install is drift.
func skillsVerdict(skillsDir string, options setupOptions) verdict {
	if strings.TrimSpace(skillsDir) == "" {
		return verdict{artifactSkills, statusSkipped, "no --skills-dir given"}
	}
	dir := settings.ExpandHome(strings.TrimSpace(skillsDir))
	if format.IsRegularFile(dir) {
		return verdict{artifactSkills, statusSkipped, dir + " is not a directory"}
	}

	// The effective templates are validated first: a broken one would
	// silently write blocks no skill can log from.
	templateDir := templatepkg.ResolveDir("")
	usage, err := templatepkg.Load(assets.UsageLogName, templateDir)
	if err != nil {
		return verdict{artifactSkills, statusDrift, err.Error()}
	}
	review, err := templatepkg.Load(assets.ReviewName, templateDir)
	if err != nil {
		return verdict{artifactSkills, statusDrift, err.Error()}
	}
	if err := document.ValidateTemplate(assets.UsageLogName, usage.Content); err != nil {
		return verdict{artifactSkills, statusDrift, err.Error()}
	}
	if err := document.ValidateTemplate(assets.ReviewName, review.Content); err != nil {
		return verdict{artifactSkills, statusDrift, err.Error()}
	}
	command := templatepkg.ResolvedCommand()

	wantedLog := skillLogDocument(usage.Content, command)
	wantedReview := reviewDocument(review.Content, usage.Content, command)

	entries := []skillInstall{
		installedSkillAction(dir, SkillLogSkill, wantedLog, options),
		installedSkillAction(dir, ReviewSkill, wantedReview, options),
	}
	created := false
	updated := false
	drift := false
	skipped := false
	for _, entry := range entries {
		switch entry.status {
		case statusCreated:
			created = true
		case statusUpdated:
			updated = true
		case statusDrift:
			drift = true
		case statusSkipped:
			skipped = true
		}
	}

	var detail strings.Builder
	for i, entry := range entries {
		if i > 0 {
			detail.WriteString(", ")
		}
		detail.WriteString(entry.text())
	}

	// A shipped default that moved since the user copy was seeded is named
	// here too: the installed skills were rendered from the old default, so
	// the install is behind — and only a human can decide to discard their
	// own wording. Under `--check` that is drift.
	moved := movedDefaultNote(usage, review)
	if moved != "" {
		if detail.Len() > 0 {
			detail.WriteString("; ")
		}
		detail.WriteString(moved)
		if options.check {
			return verdict{artifactSkills, statusDrift, detail.String()}
		}
	}

	if drift {
		return verdict{artifactSkills, statusDrift, detail.String()}
	}
	if created {
		return verdict{artifactSkills, statusCreated, detail.String()}
	}
	if updated {
		return verdict{artifactSkills, statusUpdated, detail.String()}
	}
	if skipped {
		return verdict{artifactSkills, statusSkipped, detail.String()}
	}
	return verdict{artifactSkills, statusUnchanged, detail.String()}
}

// skillInstall is one skill's install answer: its status and the reason for
// it.
//
// The status is one of the five the JSON contract names, so the aggregate can
// be decided from values rather than from prose.
type skillInstall struct {
	name   string
	status string
	reason string
}

// text is the human line: the skill, its status, and the reason.
func (s skillInstall) text() string {
	return s.name + ":" + s.status + " (" + s.reason + ")"
}

// replaceSkill writes wanted over path unless this is a dry run, and answers
// the install as `updated` with the given reason. The write is the atomic
// replacement; `--dry-run` reports the same answer and writes nothing.
func replaceSkill(name, path, wanted, reason string, options setupOptions) skillInstall {
	if !options.dryRun {
		if err := format.WriteText(path, wanted); err != nil {
			return skillInstall{name, statusDrift, err.Error()}
		}
	}
	return skillInstall{name, statusUpdated, reason}
}

// installedSkillAction is one skill's install answer, as `name:verdict` with
// its reason.
//
// The verdict is one of the five statuses the JSON contract names; the reason
// names the path and why, so an operator can act on the line alone. A
// vendored copy is skipped entirely: its wording belongs to its upstream,
// not to this tool.
func installedSkillAction(dir, name, wanted string, options setupOptions) skillInstall {
	path := dir + "/" + name + "/SKILL.md"
	if !format.IsRegularFile(path) {
		if options.check {
			return skillInstall{name, statusDrift, "missing at " + path}
		}
		if options.dryRun {
			return skillInstall{name, statusCreated, "would write " + path}
		}
		if !format.IsDir(dir + "/" + name) {
			if err := os.MkdirAll(dir+"/"+name, 0o755); err != nil {
				return skillInstall{name, statusDrift, err.Error()}
			}
		}
		if err := format.WriteText(path, wanted); err != nil {
			return skillInstall{name, statusDrift, err.Error()}
		}
		return skillInstall{name, statusCreated, path}
	}

	text, err := format.ReadText(path)
	if err != nil {
		return skillInstall{name, statusDrift, err.Error()}
	}
	if text == wanted {
		return skillInstall{name, statusUnchanged, path}
	}
	if document.IsVendored(text) {
		return skillInstall{
			name,
			statusSkipped,
			"vendored; " + path + " is left alone",
		}
	}

	// `skill-log` is copied verbatim, so the only thing that can tell a stale
	// install from a hand edit is its version stamp. The stamp reads on every
	// differing copy, `--force` or not: the reason a `--check` names is the
	// reason the copy differs.
	stamp := ""
	if name == SkillLogSkill {
		stamp = stampVersion(text)
	}
	if stamp == "" && name == SkillLogSkill {
		if options.check {
			return skillInstall{name, statusDrift, "no version stamp at " + path}
		}
		if options.force {
			return replaceSkill(name, path, wanted, path, options)
		}
		return skillInstall{
			name,
			statusSkipped,
			"no version stamp; left alone at " + path + "; use --force to replace",
		}
	}
	if stamp != "" && stamp != Version() {
		if options.check {
			return skillInstall{
				name,
				statusDrift,
				"installed by " + stamp + " at " + path,
			}
		}
		if options.force {
			return replaceSkill(
				name, path, wanted,
				"was installed by "+stamp+", this is "+Version(),
				options,
			)
		}
		// A copy another version installed is left alone: the status is
		// `skipped` (nothing was written) and the reason names both
		// versions.
		return skillInstall{
			name,
			statusSkipped,
			"installed by " + stamp + ", this is " + Version() +
				"; left alone at " + path,
		}
	}
	if options.check {
		return skillInstall{
			name,
			statusDrift,
			"differs from this version at " + path,
		}
	}
	if options.force {
		return replaceSkill(name, path, wanted, path, options)
	}
	return skillInstall{
		name,
		statusSkipped,
		"differing copy left alone at " + path + "; use --force to replace",
	}
}

// resolveSetupRepo is the checkout `setup` works on: `--repo`, else this
// checkout.
//
// Either way the answer is the git toplevel — the root the report directory
// and the hook belong to. An empty answer means no git checkout, and the
// repo-scoped artifacts are skipped rather than failing.
func resolveSetupRepo(flag string) string {
	if strings.TrimSpace(flag) != "" {
		return settings.GitToplevelOf(settings.ExpandHome(strings.TrimSpace(flag)))
	}
	return settings.GitToplevel()
}

// handleSetup is the `setup` handler. It never prints and never exits: the
// CLI boundary owns both.
func handleSetup(args []string) Outcome {
	options, err := parseSetupOptions(args)
	if err != nil {
		return usageOutcome(err)
	}

	// The machine identity the log will use, printed every run: the hostname
	// spelling is what every marker must match.
	machine, err := settings.Hostname()
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	repo := resolveSetupRepo(options.repo)
	common := ""
	if repo != "" {
		common = settings.GitCommonDir(repo)
	}

	path := settings.ResolveDB(options.db)

	// The four verdicts, in the order the JSON contract lists them.
	verdicts := []verdict{
		storeVerdict(path, options.check, options.dryRun),
		hookVerdict(common, options),
		reportDirVerdict(repo, options),
		skillsVerdict(options.skillsDir, options),
	}

	var text string
	if options.json {
		lines := make([]string, 0, len(verdicts))
		for _, item := range verdicts {
			lines = append(lines, verdictJSON(item))
		}
		text = format.JoinLines(lines)
	} else {
		lines := make([]string, 0, len(verdicts))
		for _, item := range verdicts {
			lines = append(lines, verdictLine(item))
		}
		text = "machine: " + machine + "\n" + format.JoinLines(lines)
	}

	// Any drift is the run's failure. The first one is the one stderr line;
	// the artifact lines carry every verdict.
	for _, item := range verdicts {
		if item.status == statusDrift {
			outcome := Fail(item.detail, ExitFailure)
			outcome.Text = text
			return outcome
		}
	}

	return OK(text)
}
