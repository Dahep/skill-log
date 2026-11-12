package cli

import (
	"fmt"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/store"
)

// refusalFailure renders a typed store refusal as the one named line and exit
// code the CLI reports. The store classifies; the boundary renders.
func refusalFailure(refusal *store.Refusal) Failure {
	path := refusal.Path
	switch refusal.Kind {
	case store.Damaged:
		return Failure{Message: "damaged store: " + path + " is not a skill-log database", Code: ExitFailure}
	case store.Foreign:
		return Failure{Message: "foreign store: " + path + " is not a skill-log store", Code: ExitFailure}
	case store.Older:
		return Failure{
			Message: "older store: " + path + " was written by an older skill-log schema; 1.0 does not convert it",
			Code:    ExitFailure,
		}
	case store.Newer:
		return Failure{
			Message: fmt.Sprintf(
				"newer store: %s has schema version %d, this binary understands %d",
				path, refusal.Found, store.SchemaVersion,
			),
			Code: ExitFailure,
		}
	case store.Locked:
		return Failure{Message: "locked store: " + path + " is held by another writer", Code: ExitFailure}
	default:
		return Failure{Message: "cannot use the store: " + path, Code: ExitFailure}
	}
}

// formatSanitize is the sanitizer every diagnostic and problem passes through.
func formatSanitize(text string) string { return format.Sanitize(text) }

// readFailure is the named failure for a SQLite error on the read path. The
// store classifies the error and this boundary renders the answer: damage is
// damage, a lock is a lock, and anything else is the generic operational
// failure.
func readFailure(path string, err error) Failure {
	if classified := store.ClassifyError(err); classified != nil {
		classified.Path = path
		return refusalFailure(classified)
	}
	return Failure{Message: "cannot read the store: " + path + ": " + err.Error(), Code: ExitFailure}
}
