package format

import (
	"fmt"
	"os"
	"path/filepath"
)

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
// The temporary lives beside the target — a rename across filesystems is a
// copy, not an atomic swap — and is created exclusively under an
// unpredictable name, so a file already at that name (a planted symlink
// included) is never followed. The mode is set on the descriptor before the
// rename, so the replacement is never visible at the wrong permissions and
// the process's umask cannot narrow it: a generated git hook must come out
// executable whatever the umask says.
func WriteTextMode(path, text string, mode os.FileMode) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, filepath.Base(path)+".tmp.*")
	if err != nil {
		return fmt.Errorf("cannot create a temporary file beside %s", path)
	}
	temp := file.Name()
	defer func() {
		if temp != "" {
			_ = os.Remove(temp)
		}
	}()

	if _, err := file.WriteString(text); err != nil {
		_ = file.Close()
		return fmt.Errorf("cannot write %s", path)
	}
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return fmt.Errorf("cannot set the permissions on %s", path)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("cannot write %s", path)
	}
	if err := os.Rename(temp, path); err != nil {
		return fmt.Errorf("cannot replace %s", path)
	}
	temp = ""
	return nil
}

// IsExecutable reports whether path carries an execute bit for somebody.
//
// A git hook is run only when it is executable, and git says nothing when
// it is not — the hook simply never fires. A file that cannot be stat'ed is
// not executable: the caller is asking about a hook it should have written.
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
		return fmt.Errorf("cannot make %s executable", path)
	}
	return nil
}

// ResolvePath returns path as one absolute, symlink-resolved path, or "".
//
// The answer is best-effort: a name the filesystem cannot resolve is still
// a usable command, and the caller keeps the name it was given.
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
