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
	id, err := insertInvocation(tx, row)
	if err != nil {
		return WriteResult{}, nil, err
	}
	if err := insertProblems(tx, id, 1, problems); err != nil {
		return WriteResult{}, nil, err
	}
	if err := tx.Commit(); err != nil {
		return WriteResult{}, nil, err
	}
	committed = true
	return WriteResult{ID: id}, nil, nil
}

func insertInvocation(tx *sql.Tx, row *Invocation) (int64, error) {
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
		return 0, err
	}
	return result.LastInsertId()
}

// insertProblems writes problems from start at consecutive ordinals, so an
// append continues the row's existing count.
func insertProblems(tx *sql.Tx, id int64, start int, problems []string) error {
	for i, problem := range problems {
		if _, err := tx.Exec(
			"INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, ?, ?)",
			id, start+i, problem,
		); err != nil {
			return err
		}
	}
	return nil
}

// readInvocationTx reads a row and its problems inside the transaction that
// wrote them. A read after commit would travel back through withRetry, where a
// transient failure would replay the committed write.
func readInvocationTx(tx *sql.Tx, id int64) (*Invocation, error) {
	invocation, err := scanInvocation(tx.QueryRow(invocationSelect+" WHERE id = ?", id))
	if err != nil || invocation == nil {
		return nil, err
	}
	problems, err := problemsFor(tx, id)
	if err != nil {
		return nil, err
	}
	invocation.Problems = problems
	return invocation, nil
}

// RefAppend is what a --ref write produced. A nil Row means no row carries the
// ref yet and the caller writes an ordinary row; that can only happen in a dry
// run, because the write claims the call when no row does.
type RefAppend struct {
	Row *Invocation
}

// WriteOrAppendToRef records a run that names a harness call. When a row already
// carries the ref, the problems append to it, continuing its ordinals, and no
// invocation row is written. Otherwise the row is written with the ref as a
// claim. The lookup, the claim and the append share one transaction, so two
// writers cannot both claim one call. A dry run asks the same question, writes
// nothing, and returns no Row when nothing claims the ref yet.
func WriteOrAppendToRef(path string, row *Invocation, problems []string, now string, dryRun bool) (RefAppend, *Refusal, error) {
	if row.EvidenceRef == "" {
		return RefAppend{}, nil, nil
	}
	if dryRun {
		return readRef(path, row.EvidenceRef, problems)
	}
	return withRetry(func() (RefAppend, *Refusal, error) {
		return refAttempt(path, row, problems, now)
	})
}

func readRef(path, ref string, problems []string) (RefAppend, *Refusal, error) {
	opened, refusal, err := openRead(path)
	if err != nil || refusal != nil {
		return RefAppend{}, refusal, err
	}
	if opened == nil {
		return RefAppend{}, nil, nil
	}
	defer opened.Close()
	existing, err := opened.InvocationByRef(ref)
	if err != nil || existing == nil {
		return RefAppend{}, nil, err
	}
	existing.Problems = append(existing.Problems, problems...)
	return RefAppend{Row: existing}, nil, nil
}

func refAttempt(path string, row *Invocation, problems []string, now string) (RefAppend, *Refusal, error) {
	var result RefAppend
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

	var id int64
	err = tx.QueryRow("SELECT id FROM invocations"+refLookup, row.EvidenceRef).Scan(&id)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// No row claims the call: write the claimed row and its problems here,
		// in the same transaction that found nothing, so a racing writer cannot
		// claim it too.
		row.TS = now
		id, err = insertInvocation(tx, row)
		if err != nil {
			return result, nil, err
		}
		if err := insertProblems(tx, id, 1, problems); err != nil {
			return result, nil, err
		}
	case err != nil:
		return result, nil, err
	default:
		var last int
		if err := tx.QueryRow(
			"SELECT COALESCE(MAX(ordinal), 0) FROM problems WHERE invocation_id = ?", id,
		).Scan(&last); err != nil {
			return result, nil, err
		}
		if err := insertProblems(tx, id, last+1, problems); err != nil {
			return result, nil, err
		}
	}

	stored, err := readInvocationTx(tx, id)
	if err != nil {
		return result, nil, err
	}
	if err := tx.Commit(); err != nil {
		return result, nil, err
	}
	committed = true
	result.Row = stored
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
func ResolveRow(path string, kind marker.Kind, id int64, fix, host, now string, dryRun bool) (Resolved, *Refusal, error) {
	var result Resolved
	if kind != marker.Invocation {
		// An error or signature marker is not an invocation row: the caller
		// names the row it asked for, and nothing is stamped under this table.
		return result, nil, nil
	}
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
		return result, nil, &ForeignMarker{Marker: marker.Format(row.Machine, marker.Invocation, id)}
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
		return result, nil, &ForeignMarker{Marker: marker.Format(machine, marker.Invocation, id)}
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
