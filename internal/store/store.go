// Package store is the typed store surface: one SQLite file with one schema,
// stamped with `PRAGMA user_version`.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
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
    evidence TEXT NOT NULL DEFAULT '',
    evidence_ref TEXT NOT NULL DEFAULT '',
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
	"id", "ts", "skill", "evidence", "evidence_ref", "harness", "session",
	"parent", "model", "repo", "worktree", "project", "t3_thread", "machine",
	"fix", "resolved_at",
}

var problemColumns = []string{"invocation_id", "ordinal", "problem"}

const invocationSelect = "SELECT id, ts, skill, evidence, evidence_ref," +
	" harness, session, parent, model, repo, worktree, project, t3_thread," +
	" machine, fix, resolved_at FROM invocations"

// refLookup finds the row a harness call id claims. It is one clause so the dry
// run and the write ask the same question.
const refLookup = " WHERE evidence_ref = ? AND evidence_ref <> ''" +
	" ORDER BY id DESC LIMIT 1"

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
	// ReadOnly means the store exists but cannot be written.
	ReadOnly
	// Unusable means the path cannot be opened as a store at all.
	Unusable
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

// stripPath removes the store's own path from a message, in either spelling the
// driver may use, so a path that carries a word of the taxonomy cannot choose the
// answer.
func stripPath(message, path string) string {
	if path == "" {
		return message
	}
	message = strings.ReplaceAll(message, format.FileURI(path), "")
	return strings.ReplaceAll(message, path, "")
}

func errorText(err error, path string) string {
	if err == nil {
		return ""
	}
	return stripPath(err.Error(), path)
}

func isBusy(err error, text string) bool {
	if err == nil {
		return false
	}
	switch errorCode(err) & 0xff {
	case 5, 6:
		return true
	}
	text = strings.ToLower(text)
	return strings.Contains(text, "database is locked") ||
		strings.Contains(text, "database table is locked") ||
		strings.Contains(text, "database schema is locked")
}

func isCorruption(err error, text string) bool {
	if err == nil {
		return false
	}
	switch errorCode(err) & 0xff {
	case 11, 26:
		return true
	}
	text = strings.ToLower(text)
	return strings.Contains(text, "not a database") ||
		strings.Contains(text, "malformed") ||
		strings.Contains(text, "file is encrypted")
}

// isReadOnly reports a store that exists but cannot be written: the file, or the
// directory that holds it, carries no write permission.
func isReadOnly(err error, text string) bool {
	if err == nil {
		return false
	}
	if errorCode(err)&0xff == 8 {
		return true
	}
	text = strings.ToLower(text)
	return strings.Contains(text, "readonly database") ||
		strings.Contains(text, "read-only database") ||
		strings.Contains(text, "attempt to write a readonly") ||
		strings.Contains(text, "attempt to write a read-only")
}

// isUnusable reports a path that cannot be opened as a store at all, such as a
// directory where the file should be.
func isUnusable(err error, text string) bool {
	if err == nil {
		return false
	}
	if errorCode(err)&0xff == 14 {
		return true
	}
	return strings.Contains(strings.ToLower(text), "unable to open database file")
}

// ClassifyError turns a SQLite failure into the refusal kind it means, or nil when
// it is a generic operational failure. The classification reads the engine's own
// wording only: the caller's path is stripped first.
func ClassifyError(err error, path string) *Refusal {
	text := errorText(err, path)
	switch {
	case isCorruption(err, text):
		return &Refusal{Kind: Damaged}
	case isBusy(err, text):
		return &Refusal{Kind: Locked}
	case isReadOnly(err, text):
		return &Refusal{Kind: ReadOnly}
	case isUnusable(err, text):
		return &Refusal{Kind: Unusable}
	}
	return nil
}

// CheckWritable reports a store file that does not accept a write descriptor, so
// a verb that only reads can still say the loop's writes will fail. It opens
// nothing: no PRAGMA, no transaction, no change to the file.
func CheckWritable(path string) *Refusal {
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err == nil {
		file.Close()
		return nil
	}
	if os.IsPermission(err) {
		return &Refusal{Kind: ReadOnly, Path: path}
	}
	return nil
}

func isFile(path string) bool {
	return format.IsRegularFile(path)
}

// fileHasBytes reports whether the file already carries content. A zero-byte
// file holds nothing to inherit and is created like an absent one; a file with
// bytes was written by someone and is never inherited or converted.
func fileHasBytes(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}

// openRead opens an existing store for reading. A nil store with no refusal means
// the file does not exist: a read never creates the file or an empty database.
func openRead(path string) (*Store, *Refusal, error) {
	if !isFile(path) {
		if _, statErr := os.Stat(path); statErr == nil {
			return nil, &Refusal{Kind: Unusable, Path: path}, nil
		}
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
		if isCorruption(err, errorText(err, path)) {
			return nil, &Refusal{Kind: Damaged, Path: path}, nil
		}
		return nil, nil, err
	}
	store := &Store{db: db}
	refusal, err := store.schemaRefusal(true, fileHasBytes(path))
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
	hasBytes := fileHasBytes(path)
	if err := createStoreDirectory(path); err != nil {
		return nil, nil, err
	}
	db, err := openURI(path, "")
	if err != nil {
		return nil, nil, err
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA busy_timeout=%d", writeBusyTimeout)); err != nil {
		db.Close()
		if isCorruption(err, errorText(err, path)) {
			return nil, &Refusal{Kind: Damaged, Path: path}, nil
		}
		return nil, nil, err
	}
	if !existed {
		// SQLite just created the file; tighten it to the mode every file the
		// tool writes itself gets. A file that was already there keeps its own
		// mode, and the WAL and SHM sit inside the owner-only directory.
		if err := os.Chmod(path, 0o600); err != nil {
			db.Close()
			return nil, nil, err
		}
	}
	store := &Store{db: db}
	refusal, err := store.schemaRefusal(existed, hasBytes)
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
		if isBusy(err, errorText(err, path)) {
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

// schemaRefusal refuses a file that is not this schema. hasBytes says the file
// already carried content when it was found: a zero-byte file holds nothing to
// inherit, and is treated like an absent one.
func (s *Store) schemaRefusal(existed, hasBytes bool) (*Refusal, error) {
	older, err := s.isOlder()
	if err != nil {
		if isCorruption(err, err.Error()) {
			return &Refusal{Kind: Damaged}, nil
		}
		return nil, err
	}
	if older {
		return &Refusal{Kind: Older}, nil
	}
	ours, err := s.isOurs()
	if err != nil {
		if isCorruption(err, err.Error()) {
			return &Refusal{Kind: Damaged}, nil
		}
		return nil, err
	}
	if !ours && existed && hasBytes {
		// A concurrent `add` may have committed the schema between the
		// queries: ask once more before calling the file foreign.
		ours, err = s.isOurs()
		if err != nil {
			return nil, err
		}
		if !ours {
			// A file that is already a database and not this schema is
			// refused by name: the store is created, never inherited.
			return &Refusal{Kind: Foreign}, nil
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
