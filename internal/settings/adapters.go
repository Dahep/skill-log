package settings

import (
	"encoding/json"
	"strings"

	"github.com/Dahep/skill-log/internal/store"
)

const AdaptersEnv = "SKILL_LOG_ADAPTERS"

// OpenCodeSessionEnv is the environment variable opencode exports into the
// shells it runs skills in.
const OpenCodeSessionEnv = "OPENCODE_SESSION_ID"

const openCodeDBRelative = "/.local/share/opencode/opencode.db"

// AdapterContext is what an enabled adapter filled. Every field is a string; an
// empty one means the adapter did not fill it, or that it failed.
type AdapterContext struct {
	Harness string
	Session string
	Model   string
	Project string
}

func splitCommas(text string) []string {
	var parts []string
	for _, piece := range strings.Split(text, ",") {
		if trimmed := strings.TrimSpace(piece); trimmed != "" {
			parts = append(parts, trimmed)
		}
	}
	return parts
}

// EnabledAdapters is the adapters to run: the flags' names plus
// SKILL_LOG_ADAPTERS's. Both take a comma-separated list.
func EnabledAdapters(flags []string) []string {
	var names []string
	for _, flag := range flags {
		names = append(names, splitCommas(flag)...)
	}
	names = append(names, splitCommas(EnvOrEmpty(AdaptersEnv))...)
	return names
}

// HasAdapter reports whether one of the enabled adapters is the named one. An
// adapter's value is only consulted when that adapter runs.
func HasAdapter(names []string, want string) bool {
	for _, name := range names {
		if strings.TrimSpace(name) == want {
			return true
		}
	}
	return false
}

func openCodeDBPath() string {
	return EnvOrEmpty("HOME") + openCodeDBRelative
}

// renderModel turns an opencode model value into `provider/id`. A value that is
// not a JSON object is passed through unchanged; a JSON object whose `id` and
// `providerID` are not both strings is a blank field — an adapter failure is a
// blank field, never an error.
func renderModel(raw string) string {
	if raw == "" {
		return ""
	}
	if !strings.HasPrefix(raw, "{") {
		return raw
	}
	var value struct {
		ID         json.RawMessage `json:"id"`
		ProviderID json.RawMessage `json:"providerID"`
	}
	if err := json.Unmarshal([]byte(raw), &value); err != nil {
		return ""
	}
	var modelID, provider string
	if err := json.Unmarshal(value.ID, &modelID); err != nil {
		return ""
	}
	if err := json.Unmarshal(value.ProviderID, &provider); err != nil {
		return ""
	}
	if provider == "" || modelID == "" {
		return ""
	}
	return provider + "/" + modelID
}

// ApplyAdapters runs the enabled adapters and collects what they filled. worktree is
// the worktree the run happened in. An unknown adapter name is ignored.
func ApplyAdapters(names []string, worktree string, session string) AdapterContext {
	var context AdapterContext
	for _, name := range names {
		switch strings.TrimSpace(name) {
		case "opencode":
			context.Harness = "opencode"
			if session == "" {
				session = EnvOrEmpty(OpenCodeSessionEnv)
			}
			context.Session = session
			context.Model = renderModel(store.HarnessSessionModel(openCodeDBPath(), session))
		case "t3":
			context.Project = T3Project(worktree)
		}
	}
	return context
}
