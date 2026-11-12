// Package settings resolves the writer's context: where the store lives,
// when a row happened, which machine wrote it, the git detection behind the
// repo and worktree columns, and the opt-in adapters.
package settings

import (
	"os"
	"strings"
)

// EnvOrEmpty returns the value of an environment variable, or an empty
// string. An unset variable and an empty one are the same thing to every
// caller here: the field is simply not filled.
func EnvOrEmpty(name string) string {
	return os.Getenv(name)
}

// ExpandHome expands a leading `~` to the user's home. `~` alone is the
// home directory; `~/x` is `x` inside it. A path that does not start with
// `~` is returned unchanged.
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

// DefaultDB is the store path when nothing overrides it.
//
// XDG_STATE_HOME wins; HOME/.local/state is the fallback. The directory is
// never created here: a read must not change the machine.
func DefaultDB() string {
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state + "/skill-log/skills.db"
}

// ResolveDB is the store path: --db first, then SKILL_LOG_DB, then the
// default. An empty --db means the flag was not given.
func ResolveDB(flag string) string {
	if flag != "" {
		return ExpandHome(flag)
	}
	if env := os.Getenv("SKILL_LOG_DB"); env != "" {
		return ExpandHome(env)
	}
	return DefaultDB()
}

// StateDir is the per-machine skill-log state directory: where the seeded
// template record lives, beside the store.
func StateDir() string {
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state + "/skill-log"
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

// TemplatesDir is the user-owned template directory.
func TemplatesDir() string {
	return UserConfigDir() + "/templates"
}
