package cli

import (
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
)

// The two skills `setup --skills-dir` installs.
const (
	// SkillLogSkill is the read-and-report skill, copied verbatim.
	SkillLogSkill = "skill-log"
	// ReviewSkill is the review session, rendered from its template.
	ReviewSkill = "skill-friction-review"
)

// The version stamp, on a line of its own: a comment that never touches the
// usage-log fence.
const (
	stampOpen  = "<!-- skill-log:installed version="
	stampClose = " -->"
)

func stampLine() string {
	return stampOpen + Version() + stampClose + "\n"
}

// stampVersion returns the version the stamp in document names, or "" when there
// is no stamp line. The scan is line-based: prose is not a stamp.
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

// skillLogDocument is the installed `skill-log` document: body, stamp, usage-log
// block.
func skillLogDocument(usageTemplate, command string) string {
	rendered := document.Render(usageTemplate, SkillLogSkill, command)
	return document.Append(
		assets.SkillLogBody()+"\n"+stampLine(),
		rendered.Text,
	)
}

// reviewDocument is the installed `skill-friction-review` document: the review
// template rendered with the resolved binary path, plus its usage-log block.
func reviewDocument(reviewTemplate, usageTemplate, command string) string {
	body := document.Substitute(reviewTemplate, ReviewSkill, command)
	rendered := document.Render(usageTemplate, ReviewSkill, command)
	return document.Append(body, rendered.Text)
}
