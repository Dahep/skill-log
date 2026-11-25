package store

import (
	"database/sql"
	"os"
	"strings"
)

// HarnessReason says why another product's store could not be read. It is a
// value, never an error: that store is private to the product that writes it,
// so every failure is something a caller renders as a blank field (an adapter)
// or a named skip (harvest), never as this tool's own failure.
type HarnessReason string

const (
	HarnessOK         HarnessReason = ""
	HarnessMissing    HarnessReason = "missing"
	HarnessUnreadable HarnessReason = "unreadable"
	HarnessLocked     HarnessReason = "locked"
	HarnessDrifted    HarnessReason = "drifted"
)

// HarnessStore is a read-only handle on another product's SQLite store.
type HarnessStore struct {
	db *sql.DB
}

// OpenHarnessStore opens another product's store read-only. `mode=ro` refuses
// every write at the file, `query_only` is the same guard this tool's own read
// path sets, and the handle has no write method: no caller can turn it into a
// writer, and no code path here opens the store read-write.
//
// An absent store is HarnessMissing; a path that exists but is not a store is
// HarnessUnreadable. `sql.Open` is lazy, so the open is forced here with one
// statement and a failure it raises is classified. A failure that only appears
// on a later read — a lock, a damaged file, a schema that drifted from what the
// caller expects — is ClassifyHarnessRead's job.
func OpenHarnessStore(path string) (*HarnessStore, HarnessReason) {
	if path == "" {
		return nil, HarnessMissing
	}
	if !isFile(path) {
		if _, statErr := os.Stat(path); statErr == nil {
			return nil, HarnessUnreadable
		}
		return nil, HarnessMissing
	}
	db, err := openURI(path, "?mode=ro")
	if err != nil {
		return nil, HarnessUnreadable
	}
	// This is the statement that opens the file, so a store the process cannot
	// read fails here rather than at the caller's first read. `query_only` also
	// keeps a later edit to the DSN from quietly making the handle writable.
	if _, err := db.Exec("PRAGMA query_only=ON"); err != nil {
		db.Close()
		return nil, ClassifyHarnessRead(err, path)
	}
	return &HarnessStore{db: db}, HarnessOK
}

// Close releases the handle.
func (h *HarnessStore) Close() error { return h.db.Close() }

// StringColumn reads one string cell, or "" when the row is absent or the read
// fails: the shape an adapter wants, where a harness failure is a blank field
// (SPEC §4).
func (h *HarnessStore) StringColumn(query string, args ...any) string {
	var value string
	if err := h.db.QueryRow(query, args...).Scan(&value); err != nil {
		return ""
	}
	return value
}

// ClassifyHarnessRead names why one read of a harness store failed, for the
// caller that reports a skip rather than a blank. The taxonomy follows SPEC
// §5.2: a lock, a schema that drifted, permissions that keep the store shut, or
// anything else unreadable.
func ClassifyHarnessRead(err error, path string) HarnessReason {
	if err == nil {
		return HarnessOK
	}
	text := errorText(err, path)
	if isBusy(err, text) {
		return HarnessLocked
	}
	lower := strings.ToLower(text)
	if strings.Contains(lower, "no such table") || strings.Contains(lower, "no such column") {
		return HarnessDrifted
	}
	return HarnessUnreadable
}

// harnessSessionModelSQL reads the raw model column of one harness session. The
// harness's own session store is never this schema: this one read touches it,
// and only read-only.
const harnessSessionModelSQL = "SELECT model FROM session_v2 WHERE id = ?"

// HarnessSessionModel is the raw model column the harness recorded for one
// session, or "". An empty id, a missing store, an unopenable database, an
// absent row or any error is a blank field, never an error. The raw column is
// returned as stored; decoding it is the adapter's job (SPEC §4).
func HarnessSessionModel(dbPath, sessionID string) string {
	if sessionID == "" {
		return ""
	}
	harness, reason := OpenHarnessStore(dbPath)
	if reason != HarnessOK {
		return ""
	}
	defer harness.Close()
	return harness.StringColumn(harnessSessionModelSQL, sessionID)
}
