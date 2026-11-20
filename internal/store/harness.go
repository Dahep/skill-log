package store

// harnessSessionModelSQL reads the raw model column of one harness session. The
// harness's own session store is never this schema: this one read touches it,
// and only read-only.
const harnessSessionModelSQL = "SELECT model FROM session_v2 WHERE id = ?"

// HarnessSessionModel is the raw model column the harness recorded for one
// session, or "". The harness's session store is read read-only: an empty id,
// a missing file, an unopenable database, an absent row or any error is a blank
// field, never an error. The raw column is returned as stored; decoding it is
// the adapter's job (SPEC §4: an adapter failure is a blank field).
func HarnessSessionModel(dbPath, sessionID string) string {
	if sessionID == "" {
		return ""
	}
	if !isFile(dbPath) {
		return ""
	}
	db, err := openURI(dbPath, "?mode=ro")
	if err != nil {
		return ""
	}
	defer db.Close()
	var raw string
	if err := db.QueryRow(harnessSessionModelSQL, sessionID).Scan(&raw); err != nil {
		return ""
	}
	return raw
}
