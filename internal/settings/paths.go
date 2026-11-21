// Package settings resolves the writer's context: where the store lives, when a
// row happened, which machine wrote it, the git detection, the opt-in adapters.
package settings

import (
	"os"
	"strings"
)

// EnvOrEmpty returns the value of an environment variable, or an empty string.
func EnvOrEmpty(name string) string {
	return os.Getenv(name)
}

// ExpandHome expands a leading `~` to the user's home. `~` alone is the home
// directory; `~/x` is `x` inside it.
func ExpandHome(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home := os.Getenv("HOME")
	if home == "" {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return home + path[1:]
	}
	return path
}

// DefaultDB is the store path when nothing overrides it. The directory is never
// created here: a read must not change the machine.
func DefaultDB() string {
	return stateDir() + "/skill-log/skills.db"
}

// ResolveDB is the store path: --db first, then SKILL_LOG_DB, then the default.
func ResolveDB(flag string) string {
	if flag != "" {
		return ExpandHome(flag)
	}
	if env := os.Getenv("SKILL_LOG_DB"); env != "" {
		return ExpandHome(env)
	}
	return DefaultDB()
}

// StateDir is the per-machine skill-log state directory: where the seeded template
// record lives, beside the store.
func StateDir() string {
	return stateDir() + "/skill-log"
}

// UserConfigDir is the directory the user may edit: the templates and the
// seeded-from record's sibling.
func UserConfigDir() string {
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = os.Getenv("HOME") + "/.config"
	}
	return config + "/skill-log"
}

func TemplatesDir() string {
	return UserConfigDir() + "/templates"
}

func stateDir() string {
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state
}
