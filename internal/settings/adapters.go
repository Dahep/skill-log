package settings

import (
	"database/sql"
	"strings"

	"github.com/Dahep/skill-log/internal/format"

	_ "modernc.org/sqlite"
)

// AdaptersEnv is the environment variable that names the adapters to run.
const AdaptersEnv = "SKILL_LOG_ADAPTERS"

// OpenCodeSessionEnv is the environment variable opencode exports into the
// shells it runs skills in.
const OpenCodeSessionEnv = "OPENCODE_SESSION_ID"

const openCodeDBRelative = "/.local/share/opencode/opencode.db"

const openCodeModelSQL = "SELECT model FROM session_v2 WHERE id = ?"

// AdapterContext is what an enabled adapter filled. Every field is a string;
// an empty one means the adapter did not fill it, or that it failed. An
// adapter never overwrites anything the caller said.
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

// HasAdapter reports whether one of the enabled adapters is the named one.
//
// An adapter's value is only consulted when that adapter runs: an adapter
// that is not enabled fills nothing, not even its session.
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

func isJSONSpace(ch byte) bool {
	return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t'
}

// jsonStringSpan is the index just past the closing quote of the string
// opening at at (the opening quote). Escapes are skipped as a pair, so a `\"`
// inside the string does not end it. -1 when the string never closes.
func jsonStringSpan(text string, at int) int {
	i := at + 1
	for i < len(text) {
		switch text[i] {
		case '\\':
			i += 2
			continue
		case '"':
			return i + 1
		}
		i++
	}
	return -1
}

// jsonStringValue is the text of the string that opens at at, its escapes
// resolved. A `\uXXXX` escape (or anything this reader does not recognise)
// makes the value unreadable, and the caller falls back to the raw text rather
// than writing a mangled id.
func jsonStringValue(text string, at int) string {
	end := jsonStringSpan(text, at)
	if end == -1 {
		return ""
	}
	inner := text[at+1 : end-1]
	if strings.IndexByte(inner, '\\') == -1 {
		return inner
	}
	var out strings.Builder
	for i := 0; i < len(inner); {
		if inner[i] != '\\' {
			out.WriteByte(inner[i])
			i++
			continue
		}
		if i+1 >= len(inner) {
			return ""
		}
		switch inner[i+1] {
		case '"':
			out.WriteByte('"')
		case '\\':
			out.WriteByte('\\')
		case '/':
			out.WriteByte('/')
		case 'n':
			out.WriteByte('\n')
		case 't':
			out.WriteByte('\t')
		case 'r':
			out.WriteByte('\r')
		case 'b':
			out.WriteByte('\b')
		case 'f':
			out.WriteByte('\f')
		default:
			return ""
		}
		i += 2
	}
	return out.String()
}

// jsonStringField is the value of a string field at the top level of a JSON
// object.
//
// A small targeted scanner, not a JSON parser: the only shape this tool reads
// is opencode's `{"id":"...","providerID":"..."}`. The scan tracks nesting, so
// a key spelled inside a nested object never answers for the top-level one.
func jsonStringField(text, key string) string {
	i := 0
	for i < len(text) && isJSONSpace(text[i]) {
		i++
	}
	if i >= len(text) || text[i] != '{' {
		return ""
	}
	i++
	depth := 1
	for i < len(text) {
		c := text[i]
		if c == '"' {
			end := jsonStringSpan(text, i)
			if end == -1 {
				return ""
			}
			name := jsonStringValue(text, i)
			i = end
			j := i
			for j < len(text) && isJSONSpace(text[j]) {
				j++
			}
			if j < len(text) && text[j] == ':' {
				if depth == 1 && name == key {
					k := j + 1
					for k < len(text) && isJSONSpace(text[k]) {
						k++
					}
					if k < len(text) && text[k] == '"' {
						return jsonStringValue(text, k)
					}
					return ""
				}
				i = j + 1
			}
			continue
		}
		if c == '{' || c == '[' {
			depth++
		} else if c == '}' || c == ']' {
			depth--
			if depth == 0 {
				return ""
			}
		}
		i++
	}
	return ""
}

// renderModel turns an opencode model value into `provider/id`.
//
// A value that is not the `{"id":"...","providerID":"..."}` shape is passed
// through unchanged: a value nobody can parse is better than a value silently
// mangled.
func renderModel(raw string) string {
	if raw == "" {
		return ""
	}
	if !strings.HasPrefix(raw, "{") {
		return raw
	}
	provider := jsonStringField(raw, "providerID")
	modelID := jsonStringField(raw, "id")
	if provider == "" || modelID == "" {
		return raw
	}
	return provider + "/" + modelID
}

// fileURI is the path as a `file:` URI.
func fileURI(path string) string {
	return format.FileURI(path)
}

// openCodeModel is the model of an opencode session, or "".
//
// The session store is read read-only; a missing file, a changed schema, an
// absent row — every one of them is an empty string.
func openCodeModel(sessionID string) string {
	if sessionID == "" {
		return ""
	}
	path := openCodeDBPath()
	if !format.IsRegularFile(path) {
		return ""
	}
	db, err := sql.Open("sqlite", fileURI(path)+"?mode=ro")
	if err != nil {
		return ""
	}
	defer db.Close()
	var raw string
	if err := db.QueryRow(openCodeModelSQL, sessionID).Scan(&raw); err != nil {
		return ""
	}
	return renderModel(raw)
}

// ApplyAdapters runs the enabled adapters and collects what they filled.
//
// worktree is the worktree the run happened in; session is the session the
// row will carry, already resolved by the caller's chain. The model is the
// one of *that* session.
//
// An unknown adapter name is ignored: enabling an adapter this binary does
// not know must not fail the write.
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
			context.Model = openCodeModel(context.Session)
		case "t3":
			context.Project = T3Project(worktree)
		}
	}
	return context
}
