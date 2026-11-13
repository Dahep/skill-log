// Package template resolves the usage-log templates, their provenance state,
// and the path of the running binary.
package template

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
)

// SeededDirName is the state-directory entry holding seeded-from hashes.
const SeededDirName = "seeded-from"

// Template is one effective template: its bytes, source, hash and provenance.
type Template struct {
	Name    string
	Content string
	Source  string
	Hash    string
	Moved   bool
}

// ResolveDir returns the effective template directory: flag, environment, user
// directory. The shipped defaults are the per-file fallback.
func ResolveDir(flag string) string {
	if strings.TrimSpace(flag) != "" {
		return strings.TrimSpace(flag)
	}
	if env := settings.EnvOrEmpty("SKILL_LOG_TEMPLATE_DIR"); strings.TrimSpace(env) != "" {
		return strings.TrimSpace(env)
	}
	return settings.TemplatesDir()
}

// Load returns the effective template named name.
func Load(name, templateDir string) (Template, error) {
	out := Template{Name: name, Source: "shipped"}
	if templateDir != "" {
		candidate := joinPath(templateDir, name)
		if format.IsRegularFile(candidate) {
			content, err := format.ReadText(candidate)
			if err != nil {
				return out, errors.New("cannot read template " + candidate + ": " + err.Error())
			}
			out.Content = content
			out.Source = candidate
		}
	}
	if out.Source == "shipped" {
		content, err := assets.Shipped(name)
		if err != nil {
			return out, err
		}
		out.Content = content
	}
	out.Hash = document.Hash(out.Content)
	if out.Source != "shipped" {
		seeded := ReadSeeded(name)
		if seeded != "" {
			shipped, err := assets.Shipped(name)
			if err != nil {
				return out, err
			}
			out.Moved = seeded != document.Hash(shipped)
		}
	}
	return out, nil
}

// Validate refuses a template whose placeholders are wrong.
func Validate(name string, value Template) error {
	return document.ValidateTemplate(name, value.Content)
}

// SeededPath is where the seeded-from record for name lives.
func SeededPath(name string) string {
	return joinPath(joinPath(settings.StateDir(), SeededDirName), name)
}

// ReadSeeded returns the seeded-from hash of name's user copy, or "".
func ReadSeeded(name string) string {
	path := SeededPath(name)
	if !format.IsRegularFile(path) {
		return ""
	}
	text, err := format.ReadText(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(text)
}

// WriteSeeded records the seeded-from hash for name.
func WriteSeeded(name, hashValue string) error {
	dir := joinPath(settings.StateDir(), SeededDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return format.WriteText(SeededPath(name), hashValue+"\n")
}

// ClearSeeded removes the seeded-from record for name.
func ClearSeeded(name string) {
	path := SeededPath(name)
	if format.IsRegularFile(path) {
		_ = os.Remove(path)
	}
}

// ResolvedCommand returns this binary's absolute, symlink-free path.
func ResolvedCommand() string {
	program := os.Args[0]
	if !strings.Contains(program, "/") {
		program = findInPath(program)
	}
	if real := format.ResolvePath(program); real != "" {
		return real
	}
	return program
}

func findInPath(program string) string {
	for _, entry := range filepath.SplitList(settings.EnvOrEmpty("PATH")) {
		if entry == "" {
			continue
		}
		candidate := entry + "/" + program
		if format.IsRegularFile(candidate) {
			return candidate
		}
	}
	return program
}

func joinPath(dir, name string) string { return dir + "/" + name }
