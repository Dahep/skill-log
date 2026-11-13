package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Dahep/skill-log/internal/format"
)

// Open returns the store at path. A nil store and a nil refusal mean the
// file does not exist: the caller decides what that means for its verb.
// Only create may bring a store into being.
func Open(path string, create bool) (*Store, *Refusal, error) {
	if create {
		return openWrite(path)
	}
	return openRead(path)
}

func fileURI(path string) string {
	return format.FileURI(path)
}

func openURI(path string, query string) (*sql.DB, error) {
	return sql.Open("sqlite", fileURI(path)+query)
}

func createStoreDirectory(path string) error {
	dir := filepath.Dir(path)
	if dir == "" || dir == "." {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("cannot create the store's directory: %w", err)
	}
	return nil
}
