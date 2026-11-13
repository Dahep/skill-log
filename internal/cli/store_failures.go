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

// writeFailure is the named failure for a SQLite error on the write path.
//
// The write path classifies exactly like the read path: damage is damage, a
// lock is a lock, and anything else is the generic operational failure. A
// handler that printed "cannot use the store: <path>: database is locked"
// would be handing a SQLite message to the caller instead of the store's
// own vocabulary.
func writeFailure(path string, err error) Failure {
	if classified := store.ClassifyError(err); classified != nil {
		classified.Path = path
		return refusalFailure(classified)
	}
	return Failure{Message: "cannot use the store: " + path + ": " + err.Error(), Code: ExitFailure}
}

// writeOutcome renders the two answers a write has: the refusal and the
// error. The caller asks, and gets a failure or nothing.
//
// The write path is the create policy's path, so a refusal here is the
// store's own named verdict about the file it found — damage, foreign,
// older, newer or locked — and never a SQLite message.
func writeOutcome(path string, refusal *store.Refusal, err error) *Failure {
	if err != nil {
		failure := writeFailure(path, err)
		return &failure
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return &failure
	}
	return nil
}

// openStore opens the store at path under the policy, and turns the two
// answers the caller must not forget into one failure.
//
// The cascade is the store's: open, refuse, absent. The caller says what an
// absent store means in its own words — the verb's message — and this
// helper says it, so no verb re-derives the cascade.
//
// The returned store is nil when the store is absent; the absent verdict
// says what the policy made of it, and the caller decides whether that is
// an empty answer, a refusal or nothing to do.
func openStore(path string, policy store.Policy, absentMessage string) (*store.Store, store.Absent, *Failure) {
	opened, absent, refusal, err := store.Open(path, policy)
	if err != nil {
		failure := readFailure(path, err)
		return nil, absent, &failure
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return nil, absent, &failure
	}
	switch absent {
	case store.AbsentRefused:
		failure := Failure{Message: absentMessage, Code: ExitFailure}
		return nil, absent, &failure
	case store.AbsentNothing:
		return nil, absent, nil
	}
	return opened, absent, nil
}
