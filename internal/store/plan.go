package store

import (
	"database/sql"

	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
)

// The skip reasons resolve-merged reports: the --json skipped[].reason and
// the human note carry the same value.
const (
	SkipUnknownID   = "unknown_id"
	SkipForeign     = "foreign"
	SkipLoggedAfter = "logged_after_commit"
)

// Located is one marker the scan found, and the commit and time it came
// from. Epoch is the commit time in seconds, which is what a row logged after
// the commit is compared against.
type Located struct {
	Machine string
	ID      int64
	Commit  string
	Epoch   int64
}

// Text is the marker this located value is named by.
func (l Located) Text() string { return marker.Format(l.Machine, l.ID) }

// MergedSkip is one marker a scan could not stamp, and the reason.
type MergedSkip struct {
	Row    string
	Reason string
}

// Stamped is one row a merged scan stamped: its marker, what stamped it, and
// the row it names.
type Stamped struct {
	Marker  string
	Commit  string
	Machine string
	ID      int64
}

// MergedResult is what a merged scan produced: the rows it stamped, kept, and
// skipped.
type MergedResult struct {
	Stamped   []Stamped
	Unchanged []string
	Skipped   []MergedSkip
}

// resolutionRow is the columns a merged scan needs from one invocation row.
// Logged is the row's timestamp in epoch seconds, read by SQLite so the
// comparison against a commit time needs no second ISO parser.
type resolutionRow struct {
	ID      int64
	Machine string
	Fix     string
	Logged  int64
}

func mergedRowIndex(rows []resolutionRow, machine string, id int64, localHost string) int {
	for i, row := range rows {
		stored := row.Machine
		if stored == "" {
			// A row written before the machine column existed belongs to
			// the machine reading it.
			stored = localHost
		}
		if stored == machine && row.ID == id {
			return i
		}
	}
	return -1
}

// plan decides each located marker: stamp, unchanged, or skip with a reason.
//
// Pure: no git, no clock, no store. Every marker lands in exactly one of the
// three lists. Newest wins because the scan walks commits newest first. A row
// stamped with the same commit is unchanged; a row stamped with a different
// commit is restamped, so an amended fix supersedes the earlier one. A marker
// naming another machine is foreign and is never stamped.
func plan(located []Located, rows []resolutionRow, localHost string) MergedResult {
	var result MergedResult
	for _, item := range located {
		text := item.Text()
		if item.Machine != localHost {
			result.Skipped = append(result.Skipped, MergedSkip{Row: text, Reason: SkipForeign})
			continue
		}
		index := mergedRowIndex(rows, item.Machine, item.ID, localHost)
		if index == -1 {
			result.Skipped = append(result.Skipped, MergedSkip{Row: text, Reason: SkipUnknownID})
			continue
		}
		if rows[index].Fix != "" && rows[index].Fix == item.Commit {
			result.Unchanged = append(result.Unchanged, text)
			continue
		}
		if rows[index].Logged > item.Epoch {
			result.Skipped = append(result.Skipped, MergedSkip{Row: text, Reason: SkipLoggedAfter})
			continue
		}
		result.Stamped = append(result.Stamped, Stamped{
			Marker: text, Commit: item.Commit, Machine: item.Machine, ID: item.ID,
		})
	}
	return result
}

type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

func readResolutionRows(q querier) ([]resolutionRow, error) {
	rows, err := q.Query(
		"SELECT id, machine, fix," +
			" COALESCE(CAST(strftime('%s', ts) AS INTEGER), 0)" +
			" FROM invocations",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []resolutionRow
	for rows.Next() {
		var item resolutionRow
		if err := rows.Scan(&item.ID, &item.Machine, &item.Fix, &item.Logged); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// ResolveMergedRows applies: stamp every row the scanned markers name.
//
// The first pass reads through a read connection: when nothing would change
// (the hook's usual case) no write path is opened at all, and a dry run never
// gets one either. A genuine change opens the store once, re-decides inside a
// transaction, and stamps every changed row with one resolution time.
func ResolveMergedRows(path string, located []Located, localHost string, dryRun bool) (MergedResult, *Refusal, error) {
	var empty MergedResult
	if len(located) == 0 {
		return empty, nil, nil
	}
	if !isFile(path) {
		// The store vanished between the caller's check and here. A hook must
		// not create one.
		return empty, nil, nil
	}
	opened, refusal, err := openRead(path)
	if err != nil || refusal != nil {
		return empty, refusal, err
	}
	if opened == nil {
		return empty, nil, nil
	}
	defer opened.Close()
	// A store with no tables yet is an empty log: no row carries the
	// markers, and every one of them is an unknown id.
	emptyLog, err := opened.isEmptyLog()
	if err != nil {
		return empty, nil, err
	}
	var rows []resolutionRow
	if !emptyLog {
		rows, err = readResolutionRows(opened.db)
		if err != nil {
			return empty, nil, err
		}
	}
	preview := plan(located, rows, localHost)
	if dryRun || len(preview.Stamped) == 0 {
		return preview, nil, nil
	}

	result, refusal, err := withRetry(func() (MergedResult, *Refusal, error) {
		return mergedWriteAttempt(path, located, localHost)
	})
	if err != nil || refusal != nil {
		return empty, refusal, err
	}
	return result, nil, nil
}

func mergedWriteAttempt(path string, located []Located, localHost string) (MergedResult, *Refusal, error) {
	var empty MergedResult
	if !isFile(path) {
		return empty, nil, nil
	}
	opened, refusal, err := openWrite(path)
	if err != nil || refusal != nil {
		return empty, refusal, err
	}
	defer opened.Close()

	tx, err := opened.db.Begin()
	if err != nil {
		return empty, nil, err
	}
	committed := false
	defer func() {
		if !committed {
			tx.Rollback()
		}
	}()

	stamp := settings.LocalTimestamp()
	rows, err := readResolutionRows(tx)
	if err != nil {
		return empty, nil, err
	}
	resolved := plan(located, rows, localHost)
	if len(resolved.Stamped) == 0 {
		// A concurrent writer closed every row between the preview and here.
		return resolved, nil, nil
	}
	for _, stamped := range resolved.Stamped {
		rowIndex := mergedRowIndex(rows, stamped.Machine, stamped.ID, localHost)
		if rowIndex == -1 {
			continue
		}
		if _, err := tx.Exec(
			"UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?",
			stamped.Commit, stamp, rows[rowIndex].ID,
		); err != nil {
			return empty, nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return empty, nil, err
	}
	committed = true
	return resolved, nil, nil
}
