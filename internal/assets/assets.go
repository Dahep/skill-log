// Package assets carries the two shipped default templates and the bundled `skill-log` skill body.
package assets

import (
	_ "embed"
	"fmt"
)

const (
	// UsageLogName is the fenced block adopted into every skill.
	UsageLogName = "usage-log.md"
	// ReviewName is the review skill's body, installed by `setup`.
	ReviewName = "skill-friction-review.md"
)

//go:embed templates/usage-log.md
var usageLog string

//go:embed templates/skill-friction-review.md
var review string

//go:embed skills/skill-log.md
var skillLogBody string

// SkillLogBody returns the bundled `skill-log` skill body, installed verbatim by `setup --skills-dir`.
func SkillLogBody() string { return skillLogBody }

// Names returns the two template names, in canonical order.
func Names() []string {
	return []string{UsageLogName, ReviewName}
}

// Shipped returns the shipped default called name.
func Shipped(name string) (string, error) {
	switch name {
	case UsageLogName:
		return usageLog, nil
	case ReviewName:
		return review, nil
	}
	return "", fmt.Errorf("unknown template: %s", name)
}
