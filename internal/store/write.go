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

// WriteInvocation writes one invocation and its problems, atomically.
//
// One transaction covers the invocation row and every problem row: a failed
// write leaves nothing behind. A BUSY/LOCKED failure is retried as a whole
// attempt inside the write budget, because a concurrent skill run holding the
// lock costs milliseconds, not the command.
func WriteInvocation(path string, row *Invocation, problems []string) (WriteResult, error) {
	deadline := time.Now().Add(time.Duration(writeBudgetSeconds * float64(time.Second)))
	for {
		result, err := writeAttempt(path, row, problems)
		if err == nil {
			return result, nil
		}
		if !isBusy(err) {
			return WriteResult{}, err
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return WriteResult{}, err
		}
		if remaining > writeRetrySleep {
			remaining = writeRetrySleep
		}
		time.Sleep(remaining)
	}
}

func writeAttempt(path string, row *Invocation, problems []string) (WriteResult, error) {
	opened, refusal, err := OpenWrite(path)
	if err != nil {
		return WriteResult{}, err
	}
	if refusal != nil {
		return WriteResult{Refusal: refusal}, nil
	}
	defer opened.Close()

	tx, err := opened.db.Begin()
	if err != nil {
		return WriteResult{}, err
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
		return WriteResult{}, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return WriteResult{}, err
	}
	for i, problem := range problems {
		if _, err := tx.Exec(
			"INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, ?, ?)",
			id, i+1, problem,
		); err != nil {
			return WriteResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return WriteResult{}, err
	}
	committed = true
	return WriteResult{ID: id}, nil
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
	opened, refusal, err := OpenRead(path)
	if err != nil || refusal != nil {
		return result, refusal, err
	}
	if opened == nil {
		return result, nil, nil
	}
	defer opened.Close()
	ours, err := opened.IsOurs()
	if err != nil {
		return result, nil, err
	}
	// An existing file with no store tables yet is an empty log, not an
	// error: the id it is asked for cannot exist.
	if !ours {
		return result, nil, nil
	}
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

	deadline := time.Now().Add(time.Duration(writeBudgetSeconds * float64(time.Second)))
	for {
		stamped, refusal, err := stampAttempt(path, id, fix)
		if err == nil {
			return stamped, refusal, nil
		}
		if !isBusy(err) {
			return result, nil, err
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return result, nil, err
		}
		if remaining > writeRetrySleep {
			remaining = writeRetrySleep
		}
		time.Sleep(remaining)
	}
}

func stampAttempt(path string, id int64, fix string) (Resolved, *Refusal, error) {
	var result Resolved
	opened, refusal, err := OpenWrite(path)
	if err != nil || refusal != nil {
		return result, refusal, err
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
