package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Dahep/skill-log/internal/format"
)

// Open returns the store at path. A nil store and a nil refusal mean the file
// does not exist. Only create may bring a store into being.
func Open(path string, create bool) (*Store, *Refusal, error) {
	if create {
		return openWrite(path)
	}
	return openRead(path)
}

func openURI(path string, query string) (*sql.DB, error) {
	return sql.Open("sqlite", format.FileURI(path)+query)
}

// createStoreDirectory creates the state directory the store lives in,
// owner-only. The directories above it are the user's, so they are created with
// their usual mode; a directory that already exists keeps its own mode.
func createStoreDirectory(path string) error {
	dir := filepath.Dir(path)
	if dir == "" || dir == "." {
		return nil
	}
	if parent := filepath.Dir(dir); parent != "" && parent != "." {
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return fmt.Errorf("cannot create the store's directory: %w", err)
		}
	}
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return fmt.Errorf("cannot create the store's directory: %w", err)
	}
	return nil
}
