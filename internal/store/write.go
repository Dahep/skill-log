package store

import (
	"database/sql"
	"errors"
	"time"

	"github.com/Dahep/skill-log/internal/settings"
)

// WriteResult is what a write produced: the new row's id, or the refusal.
type WriteResult struct {
	ID      int64
	Refusal *Refusal
}

// retry is the write path's retry budget.
//
// A concurrent skill run holding the store's lock costs milliseconds, not
// the command: the write waits for the lock within the budget and then
// gives up. The budget is one thing, shared by every write attempt, so a
// lock that outlives it fails the same way everywhere.
const (
	writeBudgetSeconds = 5.0
	writeRetrySleep    = 100 * time.Millisecond
)

// withRetry runs attempt until it succeeds, until the budget is spent, or
// until it fails for a reason a retry cannot fix.
//
// A BUSY/LOCKED failure is retried: it is another writer, and it lasts
// milliseconds. Every other failure is returned at once — retrying a
// damaged file would only make the failure slower.
//
// The refusal is the fourth answer, and it is retried like a busy error: a
// store whose version stamp could not run because another writer held the
// lock is the same situation as a busy statement, and it must not skip the
// budget.
func withRetry[T any](attempt func() (T, *Refusal, error)) (T, *Refusal, error) {
	deadline := time.Now().Add(time.Duration(writeBudgetSeconds * float64(time.Second)))
	for {
		result, refusal, err := attempt()
		switch {
		case refusal != nil:
			// A lock is a busy store: wait for it within the budget, the
			// same way a busy statement is waited for. Every other refusal
			// is final.
			if refusal.Kind != Locked {
				return result, refusal, nil
			}
		case err == nil:
			return result, nil, nil
		case !isBusy(err):
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

// WriteInvocation writes one invocation and its problems, atomically.
//
// One transaction covers the invocation row and every problem row: a failed
// write leaves nothing behind. A BUSY/LOCKED failure is retried as a whole
// attempt inside the write budget, because a concurrent skill run holding the
// lock costs milliseconds, not the command.
func WriteInvocation(path string, row *Invocation, problems []string) (WriteResult, error) {
	result, _, err := withRetry(func() (WriteResult, *Refusal, error) {
		return writeAttempt(path, row, problems)
	})
	return result, err
}

func writeAttempt(path string, row *Invocation, problems []string) (WriteResult, *Refusal, error) {
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

	row.TS = settings.LocalTimestamp()
	result, err := tx.Exec(
		"INSERT INTO invocations"+
			" (ts, skill, harness, session, parent, model, repo, worktree,"+
			" project, t3_thread, machine, fix, resolved_at)"+
			" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		row.TS, row.Skill, row.Harness, row.Session, row.Parent, row.Model,
		row.Repo, row.Worktree, row.Project, row.T3Thread, row.Machine,
		row.Fix, row.ResolvedAt,
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

// Resolved is one row's resolution after resolve touched it (or looked at
// it). Changed is false when the row already carried the same fix: the call
// is idempotent, and the stored resolved_at stays the one the first stamp
// wrote.
type Resolved struct {
	Found      bool
	Skill      string
	Machine    string
	Fix        string
	ResolvedAt string
	Changed    bool
}

// ResolveRow stamps one row with the commit that carries its fix.
//
// The read comes first and through a read connection: a row already carrying
// this fix is answered without a write at all, and a dry run never opens the
// store for writing. Only a genuine change opens the write path.
func ResolveRow(path string, id int64, fix string, dryRun bool) (Resolved, *Refusal, error) {
	var result Resolved
	opened, refusal, err := Read(path)
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
		result.ResolvedAt = settings.LocalTimestamp()
		result.Changed = true
		return result, nil, nil
	}

	stamped, refusal, err := withRetry(func() (Resolved, *Refusal, error) {
		return stampAttempt(path, id, fix)
	})
	if err != nil || refusal != nil {
		return result, refusal, err
	}
	return stamped, nil, nil
}

func stampAttempt(path string, id int64, fix string) (Resolved, *Refusal, error) {
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
	result.Found = true
	result.Skill = skill
	result.Machine = machine
	result.Fix = fix
	if storedFix == fix {
		// Another writer (or our own earlier attempt) already installed this
		// fix: keep its timestamp and change nothing.
		result.ResolvedAt = resolvedAt
		return result, nil, nil
	}
	stamp := settings.LocalTimestamp()
	if _, err := tx.Exec(
		"UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?", fix, stamp, id,
	); err != nil {
		return result, nil, err
	}
	result.ResolvedAt = stamp
	result.Changed = true
	if err := tx.Commit(); err != nil {
		return result, nil, err
	}
	committed = true
	return result, nil, nil
}
