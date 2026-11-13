package cli

import (
	"fmt"

	"github.com/Dahep/skill-log/internal/store"
)

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

func readFailure(path string, err error) Failure {
	if classified := store.ClassifyError(err); classified != nil {
		classified.Path = path
		return refusalFailure(classified)
	}
	return Failure{Message: "cannot read the store: " + path + ": " + err.Error(), Code: ExitFailure}
}

func writeFailure(path string, err error) Failure {
	if classified := store.ClassifyError(err); classified != nil {
		classified.Path = path
		return refusalFailure(classified)
	}
	return Failure{Message: "cannot use the store: " + path + ": " + err.Error(), Code: ExitFailure}
}

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
