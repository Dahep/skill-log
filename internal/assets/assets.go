// Package assets carries the two shipped default templates, embedded in the
// binary.
//
// The templates are the binary's defaults: `skills template show` prints
// their content, `skills template seed` copies them into the user directory,
// and every render that falls through the resolution chain ends here.
//
// The files are embedded verbatim, so the bytes the user seeds are the bytes
// the shipped default hashes — a copy in the user directory and the shipped
// default with the same bytes agree.
package assets

import (
	_ "embed"
	"fmt"
)

// The template names, in the order every command lists them.
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

// Names returns the two template names, in canonical order.
func Names() []string {
	return []string{UsageLogName, ReviewName}
}

// Shipped returns the shipped default called name.
//
// An unknown name is an error rather than an empty string: every caller names
// one of the two, and a silent empty default would render an empty block.
func Shipped(name string) (string, error) {
	switch name {
	case UsageLogName:
		return usageLog, nil
	case ReviewName:
		return review, nil
	}
	return "", fmt.Errorf("unknown template: %s", name)
}
