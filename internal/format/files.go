package format

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// FileURI is the path as a `file:` URI.
//
// The path is escaped segment by segment, so a `?`, a `#` or a `%` in a name
// cannot end the file name or start a query, and the separators stay
// separators.
func FileURI(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		absolute = path
	}
	absolute = filepath.ToSlash(absolute)
	if !strings.HasPrefix(absolute, "/") {
		absolute = "/" + absolute
	}
	segments := strings.Split(absolute, "/")
	for i, segment := range segments {
		segments[i] = url.PathEscape(segment)
	}
	return "file:" + strings.Join(segments, "/")
}

// ReadText returns the file's text, or an error naming what could not be
// read.
func ReadText(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// WriteText replaces path with text, atomically, at the report mode 0600.
func WriteText(path, text string) error {
	return WriteTextMode(path, text, 0o600)
}

// WriteTextMode replaces path with text, atomically, at exactly mode.
//
// The temporary lives beside the target and is created exclusively under an
// unpredictable name, and the mode is set on the descriptor before the rename,
// so the replacement is never visible at the wrong permissions.
func WriteTextMode(path, text string, mode os.FileMode) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, filepath.Base(path)+".tmp.*")
	if err != nil {
		return fmt.Errorf("cannot create a temporary file beside %s: %w", path, err)
	}
	temp := file.Name()
	defer func() {
		if temp != "" {
			_ = os.Remove(temp)
		}
	}()

	if _, err := file.WriteString(text); err != nil {
		_ = file.Close()
		return fmt.Errorf("cannot write %s: %w", path, err)
	}
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return fmt.Errorf("cannot set the permissions on %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("cannot write %s: %w", path, err)
	}
	if err := os.Rename(temp, path); err != nil {
		return fmt.Errorf("cannot replace %s: %w", path, err)
	}
	temp = ""
	return nil
}

// IsRegularFile reports whether path is a regular file.
func IsRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// IsDir reports whether path is a directory.
func IsDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// IsExecutable reports whether path carries an execute bit for somebody.
func IsExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}

// SetExecutable gives path the execute bits, leaving its other permissions
// alone.
func SetExecutable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, info.Mode().Perm()|0o111); err != nil {
		return fmt.Errorf("cannot make %s executable: %w", path, err)
	}
	return nil
}

// ResolvePath returns path as one absolute, symlink-resolved path, or "".
func ResolvePath(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return ""
	}
	return resolved
}
