package cli

import (
	"fmt"

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

// openStore returns the store, or the failure to report. A nil store with
// no failure means the file is absent; the verb decides what that means.
func openStore(path string, create bool) (*store.Store, *Failure) {
	opened, refusal, err := store.Open(path, create)
	if err != nil {
		failure := readFailure(path, err)
		if create {
			failure = writeFailure(path, err)
		}
		return nil, &failure
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return nil, &failure
	}
	return opened, nil
}
