package format

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// FileURI is the path as a `file:` URI. The path is escaped segment by segment,
// so a `?`, `#` or `%` in a name cannot end the file name or start a query.
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

// JoinPath is the tool's path spelling: the directory and the name joined with a
// separator, deliberately naive rather than filepath.Join's cleaning one.
func JoinPath(dir, name string) string { return dir + "/" + name }

func ReadText(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func WriteText(path, text string) error {
	return WriteTextMode(path, text, 0o600)
}

// WriteTextThroughLink writes a user-owned file: a symlink at path is kept and
// the write lands on its target, so a stowed skill or template stays a link.
func WriteTextThroughLink(path, text string) error {
	return writeText(path, text, 0o600, true)
}

// WriteTextMode replaces the file at path with text, atomically. The path is the
// file the tool owns: a symlink planted there is replaced, never followed, so a
// write cannot land outside the directory the contract names. A file that
// exists keeps its own mode; only a newly created file gets mode.
func WriteTextMode(path, text string, mode os.FileMode) error {
	return writeText(path, text, mode, false)
}

// writeText stages the text beside its target and renames it into place. The
// temporary is created exclusively under an unpredictable name.
func writeText(path, text string, mode os.FileMode, follow bool) error {
	target := path
	if follow {
		if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
			resolved, err := filepath.EvalSymlinks(path)
			if err != nil {
				return fmt.Errorf("cannot resolve %s: %w", path, err)
			}
			target = resolved
		}
	}
	if info, err := os.Stat(target); err == nil && info.Mode().IsRegular() {
		mode = info.Mode().Perm()
	}
	dir := filepath.Dir(target)
	file, err := os.CreateTemp(dir, filepath.Base(target)+".tmp.*")
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
	if err := os.Rename(temp, target); err != nil {
		return fmt.Errorf("cannot replace %s: %w", path, err)
	}
	temp = ""
	return nil
}

func IsRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func IsDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func IsExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}

// IsOwnerExecutable reports whether the file's owner may execute it. git runs a
// hook as the user who pulled, and setup writes the hook as that user, so the
// owner's bit is the one that decides whether git runs it: a mode of 0641 has
// the execute bit for other and none for the owner, so the owner cannot run it.
func IsOwnerExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Mode().Perm()&0o100 != 0
}

// SetOwnerExecutable adds the owner's execute bit, leaving the other bits alone.
func SetOwnerExecutable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, info.Mode().Perm()|0o100); err != nil {
		return fmt.Errorf("cannot make %s executable: %w", path, err)
	}
	return nil
}

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
