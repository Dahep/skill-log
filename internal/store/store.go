// Package store is the typed store surface: one SQLite file with one schema,
// stamped with `PRAGMA user_version`.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/Dahep/skill-log/internal/format"

	_ "modernc.org/sqlite"
)

// SchemaVersion is the schema version this binary writes and understands. A store
// stamped higher is refused: an older CLI must not touch a newer store.
const SchemaVersion = 1

const invocationDDL = `CREATE TABLE IF NOT EXISTS invocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT '',
    skill TEXT NOT NULL DEFAULT '',
    harness TEXT NOT NULL DEFAULT '',
    session TEXT NOT NULL DEFAULT '',
    parent TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    repo TEXT NOT NULL DEFAULT '',
    worktree TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '',
    t3_thread TEXT NOT NULL DEFAULT '',
    machine TEXT NOT NULL DEFAULT '',
    fix TEXT NOT NULL DEFAULT '',
    resolved_at TEXT NOT NULL DEFAULT ''
)`

const problemDDL = `CREATE TABLE IF NOT EXISTS problems (
    invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    problem TEXT NOT NULL,
    PRIMARY KEY (invocation_id, ordinal)
)`

// The invocations column list, written once and read by the DDL's readers, the
// single-row read and the multi-row read.
var invocationColumns = []string{
	"id", "ts", "skill", "harness", "session", "parent", "model", "repo",
	"worktree", "project", "t3_thread", "machine", "fix", "resolved_at",
}

var problemColumns = []string{"invocation_id", "ordinal", "problem"}

const invocationSelect = "SELECT id, ts, skill, harness, session, parent," +
	" model, repo, worktree, project, t3_thread, machine, fix, resolved_at" +
	" FROM invocations"

const (
	writeBusyTimeout = 2000
	readBusyTimeout  = 5000
)

// DefaultLimit is the number of rows a read returns when the caller does not say:
// enough to see the recent shape of the log without filling a terminal.
const DefaultLimit = 20

type Kind int

const (
	// None means no refusal.
	None Kind = iota
	// Damaged means the file is not a usable SQLite database.
	Damaged
	// Foreign means the file is a SQLite database that is not a skill-log store.
	Foreign
	// Older means a store whose schema predates this one.
	Older
	// Newer means a store written by a newer schema than this binary.
	Newer
	// Locked means another writer is holding the store.
	Locked
)

// Refusal is a store that was refused, and why. Found is the version a newer store
// carries, and zero for every other kind.
type Refusal struct {
	Kind  Kind
	Path  string
	Found int
}

type Store struct {
	db *sql.DB
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

type coder interface {
	Code() int
}

func errorCode(err error) int {
	var c coder
	if errors.As(err, &c) {
		return c.Code()
	}
	return 0
}

func isBusy(err error) bool {
	if err == nil {
		return false
	}
	switch errorCode(err) & 0xff {
	case 5, 6:
		return true
	}
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "locked") || strings.Contains(text, "busy")
}

func isCorruption(err error) bool {
	if err == nil {
		return false
	}
	switch errorCode(err) & 0xff {
	case 11, 26:
		return true
	}
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "not a database") ||
		strings.Contains(text, "malformed") ||
		strings.Contains(text, "file is encrypted")
}

// ClassifyError turns a SQLite failure into the refusal kind it means, or nil when
// it is a generic operational failure.
func ClassifyError(err error) *Refusal {
	if isCorruption(err) {
		return &Refusal{Kind: Damaged}
	}
	if isBusy(err) {
		return &Refusal{Kind: Locked}
	}
	return nil
}

func isFile(path string) bool {
	return format.IsRegularFile(path)
}

// openRead opens an existing store for reading. A nil store with no refusal means
// the file does not exist: a read never creates the file or an empty database.
func openRead(path string) (*Store, *Refusal, error) {
	if !isFile(path) {
		return nil, nil, nil
	}
	db, err := openURI(path, "?mode=ro")
	if err != nil {
		return nil, nil, err
	}
	// The busy timeout is connection state, not file state, so it comes before
	// the schema check: a read must wait for the write lock.
	if _, err := db.Exec(fmt.Sprintf("PRAGMA busy_timeout=%d", readBusyTimeout)); err != nil {
		db.Close()
		if isCorruption(err) {
			return nil, &Refusal{Kind: Damaged, Path: path}, nil
		}
		return nil, nil, err
	}
	store := &Store{db: db}
	refusal, err := store.schemaRefusal(true)
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	if refusal != nil {
		db.Close()
		refusal.Path = path
		if refusal.Kind == None {
			refusal.Kind = Damaged
		}
		return nil, refusal, nil
	}
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		db.Close()
		return nil, nil, err
	}
	// No statement on this connection may write: a read path that grew a write
	// would fail loudly instead of changing the store.
	if _, err := db.Exec("PRAGMA query_only=ON"); err != nil {
		db.Close()
		return nil, nil, err
	}
	return store, nil, nil
}

// openWrite opens the store for writing, creating it when it does not exist. The
// state directory and the file are created here, and only here.
func openWrite(path string) (*Store, *Refusal, error) {
	existed := isFile(path)
	if err := createStoreDirectory(path); err != nil {
		return nil, nil, err
	}
	db, err := openURI(path, "")
	if err != nil {
		return nil, nil, err
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA busy_timeout=%d", writeBusyTimeout)); err != nil {
		db.Close()
		if isCorruption(err) {
			return nil, &Refusal{Kind: Damaged, Path: path}, nil
		}
		return nil, nil, err
	}
	store := &Store{db: db}
	refusal, err := store.schemaRefusal(existed)
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	if refusal != nil {
		db.Close()
		refusal.Path = path
		if refusal.Kind == None {
			refusal.Kind = Damaged
		}
		return nil, refusal, nil
	}
	ours, err := store.isOurs()
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	if !ours {
		// Both tables, one transaction: a failure on the second statement must
		// not leave a half-built store behind for good.
		tx, err := db.Begin()
		if err != nil {
			db.Close()
			return nil, nil, err
		}
		if _, err := tx.Exec(invocationDDL); err != nil {
			tx.Rollback()
			db.Close()
			return nil, nil, fmt.Errorf("cannot create the store's schema: %w", err)
		}
		if _, err := tx.Exec(problemDDL); err != nil {
			tx.Rollback()
			db.Close()
			return nil, nil, fmt.Errorf("cannot create the store's schema: %w", err)
		}
		if err := tx.Commit(); err != nil {
			db.Close()
			return nil, nil, fmt.Errorf("cannot create the store's schema: %w", err)
		}
	}
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, nil, err
	}
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		db.Close()
		return nil, nil, err
	}
	// Stamping the version is the first write to the file: another writer holding
	// the lock makes it fail, and a lock is a named refusal.
	if _, err := db.Exec(fmt.Sprintf("PRAGMA user_version=%d", SchemaVersion)); err != nil {
		db.Close()
		if isBusy(err) {
			return nil, &Refusal{Kind: Locked, Path: path}, nil
		}
		return nil, nil, err
	}
	return store, nil, nil
}

func (s *Store) isOurs() (bool, error) {
	has, err := s.hasTables()
	if err != nil || !has {
		return false, err
	}
	missing, err := s.missingColumns("invocations", invocationColumns)
	if err != nil || len(missing) > 0 {
		return false, err
	}
	missing, err = s.missingColumns("problems", problemColumns)
	if err != nil {
		return false, err
	}
	return len(missing) == 0, nil
}

func (s *Store) isOlder() (bool, error) {
	has, err := s.hasTables()
	if err != nil || !has {
		return false, err
	}
	missing, err := s.missingColumns("invocations", invocationColumns)
	if err != nil {
		return false, err
	}
	return len(missing) > 0, nil
}

func (s *Store) schemaRefusal(existed bool) (*Refusal, error) {
	older, err := s.isOlder()
	if err != nil {
		if isCorruption(err) {
			return &Refusal{Kind: Damaged}, nil
		}
		return nil, err
	}
	if older {
		return &Refusal{Kind: Older}, nil
	}
	ours, err := s.isOurs()
	if err != nil {
		if isCorruption(err) {
			return &Refusal{Kind: Damaged}, nil
		}
		return nil, err
	}
	if !ours && existed {
		tables, err := s.userTableCount()
		if err != nil {
			if isCorruption(err) {
				return &Refusal{Kind: Damaged}, nil
			}
			return nil, err
		}
		version, err := s.userVersion()
		if err != nil {
			if isCorruption(err) {
				return &Refusal{Kind: Damaged}, nil
			}
			return nil, err
		}
		if tables > 0 || version != 0 {
			// A concurrent `add` may have committed the schema between those two
			// queries: ask once more before calling the file foreign.
			ours, err = s.isOurs()
			if err != nil {
				return nil, err
			}
			if !ours {
				return &Refusal{Kind: Foreign}, nil
			}
		}
	}
	if ours {
		version, err := s.userVersion()
		if err != nil {
			return nil, err
		}
		if version > SchemaVersion {
			return &Refusal{Kind: Newer, Found: version}, nil
		}
	}
	return nil, nil
}

func (s *Store) tableExists(name string) (bool, error) {
	var one int
	err := s.db.QueryRow(
		"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name,
	).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Store) hasTables() (bool, error) {
	invocations, err := s.tableExists("invocations")
	if err != nil {
		return false, err
	}
	if !invocations {
		return false, nil
	}
	return s.tableExists("problems")
}

func (s *Store) columnsOf(table string) ([]string, error) {
	rows, err := s.db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var cid int
		var name, kind string
		var notNull, primaryKey int
		var defaultValue any
		if err := rows.Scan(&cid, &name, &kind, &notNull, &defaultValue, &primaryKey); err != nil {
			return nil, err
		}
		names = append(names, name)
	}
	return names, rows.Err()
}

func (s *Store) missingColumns(table string, required []string) ([]string, error) {
	have, err := s.columnsOf(table)
	if err != nil {
		return nil, err
	}
	present := make(map[string]bool, len(have))
	for _, name := range have {
		present[name] = true
	}
	var missing []string
	for _, name := range required {
		if !present[name] {
			missing = append(missing, name)
		}
	}
	return missing, nil
}

func (s *Store) userVersion() (int, error) {
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return 0, err
	}
	return version, nil
}

func (s *Store) userTableCount() (int, error) {
	var count int
	err := s.db.QueryRow(
		"SELECT count(*) FROM sqlite_master WHERE type = 'table'" +
			" AND name NOT LIKE 'sqlite_%'",
	).Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}
