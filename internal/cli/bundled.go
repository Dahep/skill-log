package cli

import (
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
)

// The two bundled skills `setup --skills-dir` installs.
//
// The tool ships its own documentation, as skills an agent reads:
//
//  1. **`skill-log`** — read and report. The body is embedded in the binary
//     and installed verbatim, plus one version-stamp line. The stamp names
//     the `--version` value that wrote the copy and is the copied skill's
//     only provenance: the body has no fence of its own, and the stamp is
//     what `setup --check` reads to tell a stale install from a differing
//     one.
//  2. **`skill-friction-review`** — the review session. Not a constant: it
//     is the effective `skill-friction-review.md` template with `<command>`
//     substituted, followed by the usage-log block rendered for
//     `skill-friction-review`. Customising it means editing the template,
//     not the installed file.
//
// Both documents end with their own usage-log block — the fenced block
// document.Render produces from the effective `usage-log.md` template — so a
// fresh install audits `ok` and the skills log their own runs like every
// other skill. The body says a reader never calls `add`; that means a read
// never writes a row as a side effect, not that the skill is exempt from its
// own usage log.
//
// The body is deliberately harness-neutral: it names no agent product. It
// teaches `show`, `stats`, `show --json` for pipes, the model and machine
// cuts, the `machine#id` marker grammar, the `report` / `resolve` /
// `resolve-merged` flow, and the deliberate non-idempotency of `add`.

// The two installed skills, as the directories `--skills-dir` holds.
const (
	// SkillLogSkill is the read-and-report skill, copied verbatim.
	SkillLogSkill = "skill-log"
	// ReviewSkill is the review session, rendered from its template.
	ReviewSkill = "skill-friction-review"
)

// The version stamp, on a line of its own. It is a comment: invisible in
// rendered markdown, and it never touches the usage-log fence.
const (
	stampOpen  = "<!-- skill-log:installed version="
	stampClose = " -->"
)

// stampLine is this build's version-stamp line, newline included.
func stampLine() string {
	return stampOpen + Version() + stampClose + "\n"
}

// stampVersion returns the version the stamp in document names, or "" when
// there is no stamp line.
//
// The scan is line-based on purpose — the stamp is one comment line at a
// line start, and prose that merely mentions it is not a stamp. A stamp line
// that is cut short names nothing, which the caller reports the same as a
// missing stamp.
func stampVersion(document string) string {
	n := len(document)
	at := 0
	for at <= n {
		if strings.HasPrefix(document[at:], stampOpen) {
			rest := document[at+len(stampOpen):]
			cut := strings.Index(rest, stampClose)
			if cut < 0 {
				return ""
			}
			return rest[:cut]
		}
		newline := strings.Index(document[at:], "\n")
		if newline < 0 {
			return ""
		}
		at = at + newline + 1
	}
	return ""
}

// skillLogDocument is the installed `skill-log` document: body, stamp,
// usage-log block.
//
// The body goes in verbatim — no placeholder is substituted into it — and
// the block is document.Render's render of the effective usage-log template
// for name `skill-log`, so `skills audit` classifies a fresh install `ok` and
// the skill's own runs log under its own name.
func skillLogDocument(usageTemplate, command string) string {
	rendered := document.Render(usageTemplate, SkillLogSkill, command)
	return document.Append(
		assets.SkillLogBody()+"\n"+stampLine(),
		rendered.Text,
	)
}

// reviewDocument is the installed `skill-friction-review` document: the
// review template rendered with the resolved binary path, followed by the
// usage-log block rendered for `skill-friction-review`.
func reviewDocument(reviewTemplate, usageTemplate, command string) string {
	body := document.Substitute(reviewTemplate, ReviewSkill, command)
	rendered := document.Render(usageTemplate, ReviewSkill, command)
	return document.Append(body, rendered.Text)
}
