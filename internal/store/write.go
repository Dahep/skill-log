package store

import (
	"database/sql"
	"errors"
	"time"

	"github.com/Dahep/skill-log/internal/marker"
)

type WriteResult struct {
	ID      int64
	Refusal *Refusal
}

// The write path's retry budget. A concurrent skill run holding the store's lock
// costs milliseconds, not the command: the write waits, then gives up.
const (
	writeBudgetSeconds = 5.0
	writeRetrySleep    = 100 * time.Millisecond
)

// withRetry runs attempt until it succeeds, until the budget is spent, or until it
// fails for a reason a retry cannot fix. BUSY/LOCKED is retried.
func withRetry[T any](attempt func() (T, *Refusal, error)) (T, *Refusal, error) {
	deadline := time.Now().Add(time.Duration(writeBudgetSeconds * float64(time.Second)))
	for {
		result, refusal, err := attempt()
		switch {
		case refusal != nil:
			// Every refusal but a lock is final.
			if refusal.Kind != Locked {
				return result, refusal, nil
			}
		case err == nil:
			return result, nil, nil
		case !isBusy(err, err.Error()):
			return result, nil, err
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			if refusal != nil {
				return result, refusal, nil
			}
			return result, nil, err
		}
		if remaining > writeRetrySleep {
			remaining = writeRetrySleep
		}
		time.Sleep(remaining)
	}
}

// WriteInvocation writes one invocation and its problems, atomically: one
// transaction covers the invocation row and every problem row. now is the
// writer's stamp, from the caller's clock.
func WriteInvocation(path string, row *Invocation, problems []string, now string) (WriteResult, error) {
	result, _, err := withRetry(func() (WriteResult, *Refusal, error) {
		return writeAttempt(path, row, problems, now)
	})
	return result, err
}

func writeAttempt(path string, row *Invocation, problems []string, now string) (WriteResult, *Refusal, error) {
	opened, refusal, err := openWrite(path)
	if err != nil {
		return WriteResult{}, nil, err
	}
	if refusal != nil {
		return WriteResult{Refusal: refusal}, refusal, nil
	}
	defer opened.Close()

	tx, err := opened.db.Begin()
	if err != nil {
		return WriteResult{}, nil, err
	}
	committed := false
	defer func() {
		if !committed {
			tx.Rollback()
		}
	}()

	row.TS = now
	result, err := tx.Exec(
		"INSERT INTO invocations"+
			" (ts, skill, evidence, evidence_ref, harness, session, parent, model,"+
			" repo, worktree, project, t3_thread, machine, fix, resolved_at)"+
			" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		row.TS, row.Skill, row.Evidence, row.EvidenceRef, row.Harness,
		row.Session, row.Parent, row.Model, row.Repo, row.Worktree,
		row.Project, row.T3Thread, row.Machine, row.Fix, row.ResolvedAt,
	)
	if err != nil {
		return WriteResult{}, nil, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return WriteResult{}, nil, err
	}
	for i, problem := range problems {
		if _, err := tx.Exec(
			"INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, ?, ?)",
			id, i+1, problem,
		); err != nil {
			return WriteResult{}, nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return WriteResult{}, nil, err
	}
	committed = true
	return WriteResult{ID: id}, nil, nil
}

// InvocationByRefPath reads the row a harness call id already names, or nil.
// A read never creates a store.
func InvocationByRefPath(path, ref string) (*Invocation, error) {
	opened, refusal, err := openRead(path)
	if err != nil {
		return nil, err
	}
	if refusal != nil || opened == nil {
		return nil, nil
	}
	defer opened.Close()
	return opened.InvocationByRef(ref)
}

// RefAppend is what appending to an already-harvested row produced. A nil Row
// means no row carries the ref yet, and the caller writes a new claimed row.
type RefAppend struct {
	Row     *Invocation
	Refusal *Refusal
}

// AppendProblemsToRef appends problems to the row the harness call id already
// names, continuing that row's ordinals, and writes no invocation row. The read
// and the write share one transaction, so a concurrent writer cannot split them.
func AppendProblemsToRef(path, ref string, problems []string) (RefAppend, error) {
	result, _, err := withRetry(func() (RefAppend, *Refusal, error) {
		return appendAttempt(path, ref, problems)
	})
	return result, err
}

func appendAttempt(path, ref string, problems []string) (RefAppend, *Refusal, error) {
	var result RefAppend
	if ref == "" || len(problems) == 0 {
		return result, nil, nil
	}
	opened, refusal, err := openWrite(path)
	if err != nil || refusal != nil {
		return RefAppend{Refusal: refusal}, refusal, err
	}
	defer opened.Close()

	tx, err := opened.db.Begin()
	if err != nil {
		return RefAppend{}, nil, err
	}
	committed := false
	defer func() {
		if !committed {
			tx.Rollback()
		}
	}()

	var id int64
	err = tx.QueryRow(
		"SELECT id FROM invocations WHERE evidence_ref = ? AND evidence_ref <> ''"+
			" ORDER BY id DESC LIMIT 1", ref,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		// No row claims this call: the caller writes one.
		return RefAppend{}, nil, nil
	}
	if err != nil {
		return RefAppend{}, nil, err
	}
	var last int
	if err := tx.QueryRow(
		"SELECT COALESCE(MAX(ordinal), 0) FROM problems WHERE invocation_id = ?", id,
	).Scan(&last); err != nil {
		return RefAppend{}, nil, err
	}
	for i, problem := range problems {
		if _, err := tx.Exec(
			"INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, ?, ?)",
			id, last+1+i, problem,
		); err != nil {
			return RefAppend{}, nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return RefAppend{}, nil, err
	}
	committed = true

	row, err := opened.ReadInvocation(id)
	if err != nil {
		return RefAppend{}, nil, err
	}
	result.Row = row
	return result, nil, nil
}

// Resolved is one row's resolution after resolve touched it (or looked at it).
// Changed is false when the row carried the same fix: the call is idempotent.
type Resolved struct {
	Found      bool
	Skill      string
	Machine    string
	Fix        string
	ResolvedAt string
	Changed    bool
}

// ForeignMarker is a row naming another machine: only this host's own spelling
// stamps, so the row is refused and left untouched.
type ForeignMarker struct {
	Marker string
}

func (f *ForeignMarker) Error() string {
	return "foreign marker " + f.Marker + ": only this host's spelling stamps"
}

// foreignRow reports whether a stored row names another machine. An empty
// machine column is this host's own: the row belongs to the machine reading it.
// An unknown host cannot establish this host's spelling, so a named row is
// foreign: only this host's own spelling stamps.
func foreignRow(machine, host string) bool {
	if machine == "" {
		return false
	}
	return machine != host
}

// ResolveRow stamps one row with the commit that carries its fix. The read comes
// first: a row already carrying this fix is answered without a write. host is
// this machine's hostname (or "" when it cannot be read); now is the caller's
// stamp, which a dry run reports instead of writing.
func ResolveRow(path string, id int64, fix, host, now string, dryRun bool) (Resolved, *Refusal, error) {
	var result Resolved
	opened, refusal, err := openRead(path)
	if err != nil || refusal != nil {
		return result, refusal, err
	}
	if opened == nil {
		return result, nil, nil
	}
	defer opened.Close()
	row, err := opened.ReadInvocation(id)
	if err != nil {
		return result, nil, err
	}
	if row == nil {
		return result, nil, nil
	}
	if foreignRow(row.Machine, host) {
		return result, nil, &ForeignMarker{Marker: marker.Format(row.Machine, id)}
	}
	result.Found = true
	result.Skill = row.Skill
	result.Machine = row.Machine
	result.Fix = fix
	if row.Fix == fix {
		// The same fix again is a no-op: keep the first stamp's time.
		result.ResolvedAt = row.ResolvedAt
		return result, nil, nil
	}
	if dryRun {
		result.ResolvedAt = now
		result.Changed = true
		return result, nil, nil
	}

	stamped, refusal, err := withRetry(func() (Resolved, *Refusal, error) {
		return stampAttempt(path, id, fix, host, now)
	})
	if err != nil || refusal != nil {
		return result, refusal, err
	}
	return stamped, nil, nil
}

func stampAttempt(path string, id int64, fix, host, now string) (Resolved, *Refusal, error) {
	var result Resolved
	opened, refusal, err := openWrite(path)
	if err != nil {
		return result, nil, err
	}
	if refusal != nil {
		return result, refusal, nil
	}
	defer opened.Close()

	tx, err := opened.db.Begin()
	if err != nil {
		return result, nil, err
	}
	committed := false
	defer func() {
		if !committed {
			tx.Rollback()
		}
	}()

	var skill, machine, storedFix, resolvedAt string
	err = tx.QueryRow(
		"SELECT skill, machine, fix, resolved_at FROM invocations WHERE id = ?", id,
	).Scan(&skill, &machine, &storedFix, &resolvedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// Nothing to stamp; the transaction has written nothing.
			return result, nil, nil
		}
		return result, nil, err
	}
	if foreignRow(machine, host) {
		// The stamp is the write: the guard repeats where it lands.
		return result, nil, &ForeignMarker{Marker: marker.Format(machine, id)}
	}
	result.Found = true
	result.Skill = skill
	result.Machine = machine
	result.Fix = fix
	if storedFix == fix {
		// Another writer already installed this fix: keep its timestamp and
		// change nothing.
		result.ResolvedAt = resolvedAt
		return result, nil, nil
	}
	if _, err := tx.Exec(
		"UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?", fix, now, id,
	); err != nil {
		return result, nil, err
	}
	result.ResolvedAt = now
	result.Changed = true
	if err := tx.Commit(); err != nil {
		return result, nil, err
	}
	committed = true
	return result, nil, nil
}
