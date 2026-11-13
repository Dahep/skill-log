package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Dahep/skill-log/internal/format"
)

// Policy is how a verb treats the store.
//
// The policy, not the verb, decides what an absent, empty, damaged, foreign,
// older or newer store means (SPEC §3). The six policies are the six
// answers the table in SPEC §3 gives; a verb that re-derived the cascade
// would be a second copy of that table.
type Policy int

const (
	// PolicyCreate creates the store when it is absent.
	PolicyCreate Policy = iota
	// PolicyRead reads an absent store as an empty answer.
	PolicyRead
	// PolicyStrict refuses an absent store.
	PolicyStrict
	// PolicyWrite refuses an absent store.
	PolicyWrite
	// PolicyOptional treats an absent store as nothing to do.
	PolicyOptional
	// PolicyVerify reports an absent store as drift.
	PolicyVerify
)

// String is the policy's name, for a diagnostic that names it.
func (p Policy) String() string {
	switch p {
	case PolicyCreate:
		return "create"
	case PolicyRead:
		return "read"
	case PolicyStrict:
		return "strict"
	case PolicyWrite:
		return "write"
	case PolicyOptional:
		return "optional"
	case PolicyVerify:
		return "verify"
	}
	return "unknown"
}

// Absent is what the policy says an absent store means.
//
// The store decides it; the verb renders its own wording — report's
// "(run add first)", resolve's "(add a row first)", setup's "no store at
// <path>" — because the wording is the verb's, and the store owns no
// message text.
//
// AbsentEmpty is also the answer when the store is there: it is the "the
// store is not absent" value, and the read policy's answer for a missing
// one.
type Absent int

const (
	// AbsentEmpty means the store is not absent: either it is there, or
	// the read policy says a missing one is the empty answer.
	AbsentEmpty Absent = iota
	// AbsentRefused is the refusal: the verb names the missing store and
	// fails (the strict and write policies).
	AbsentRefused
	// AbsentNothing is nothing to do: the verb carries on and says nothing
	// (the optional policy).
	AbsentNothing
	// AbsentDrift is drift: the verb reports the store as not set up (the
	// verify policy).
	AbsentDrift
)

// Open opens the store at path under the policy.
//
// It returns the store, the verdict on an absent store, a typed refusal,
// and the error that stopped it. Exactly one of the store and the refusal
// is set; absent is only set when there is no store and no refusal.
//
// The shape is small on purpose: one call answers "may I use this store,
// and what is it", so no caller re-derives the cascade.
func Open(path string, policy Policy) (opened *Store, absent Absent, refusal *Refusal, err error) {
	switch policy {
	case PolicyCreate:
		opened, refusal, err = Create(path)
		if err != nil || refusal != nil {
			return nil, AbsentEmpty, refusal, err
		}
		return opened, AbsentEmpty, nil, nil
	case PolicyRead:
		opened, refusal, err = Read(path)
		if err != nil || refusal != nil {
			return nil, AbsentEmpty, refusal, err
		}
		if opened == nil {
			return nil, AbsentEmpty, nil, nil
		}
		return opened, AbsentEmpty, nil, nil
	case PolicyStrict, PolicyWrite:
		opened, refusal, err = Read(path)
		if err != nil || refusal != nil {
			return nil, AbsentRefused, refusal, err
		}
		if opened == nil {
			return nil, AbsentRefused, nil, nil
		}
		return opened, AbsentEmpty, nil, nil
	case PolicyOptional:
		opened, refusal, err = Read(path)
		if err != nil || refusal != nil {
			return nil, AbsentNothing, refusal, err
		}
		if opened == nil {
			return nil, AbsentNothing, nil, nil
		}
		return opened, AbsentEmpty, nil, nil
	case PolicyVerify:
		gone, refusal, err := verify(path)
		if err != nil || refusal != nil {
			return nil, AbsentDrift, refusal, err
		}
		if gone {
			return nil, AbsentDrift, nil, nil
		}
		return nil, AbsentEmpty, nil, nil
	}
	return nil, AbsentEmpty, nil, fmt.Errorf("unknown store policy: %d", int(policy))
}

// Read opens the store at path for reading.
//
// A nil store with no refusal means the file does not exist: a read never
// creates the state directory, the file, or an empty database. A file that
// exists but is not a usable store is refused by name; nothing is written to
// it, not even its journal mode.
func Read(path string) (*Store, *Refusal, error) {
	return openRead(path)
}

// Create opens the store for writing, creating it when it does not exist.
//
// The create policy, named for the caller that wants it. A refusal is the
// store's answer about the file it found; the caller renders it.
func Create(path string) (*Store, *Refusal, error) {
	return openWrite(path)
}

// fileURI is the path as a `file:` URI.
//
// The encoding lives in the format package, so the store and the settings
// package — which opens another tool's database read-only — name the same
// file for the same path.
func fileURI(path string) string {
	return format.FileURI(path)
}

// openURI opens the store at path with the query the driver reads.
//
// The read-only open and the read-write open use the same URI builder, so
// a path with a reserved character names one file for both. The write open
// adds the mode that creates the file; the read open never does.
func openURI(path string, query string) (*sql.DB, error) {
	return sql.Open("sqlite", fileURI(path)+query)
}

// createStoreDirectory makes the store's directory, if it needs one.
//
// Only the create policy brings a store into being, so only the create
// path may create the directory that holds it.
func createStoreDirectory(path string) error {
	dir := filepath.Dir(path)
	if dir == "" || dir == "." {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("cannot create the store's directory: %w", err)
	}
	return nil
}
