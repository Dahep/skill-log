package settings

import "strings"

// Context is every context column, resolved.
type Context struct {
	Harness, Session, Parent, Model, Repo, Worktree, Project, T3Thread, Machine string
}

// Detected is what built-in detection answers before any adapter runs.
type Detected struct {
	Repo     string
	Worktree string
}

// ContextSource is a column's source after its flag and SKILL_LOG_* variable.
type ContextSource int

const (
	// SourceNone: the flag and the variable are the column's only sources.
	SourceNone ContextSource = iota
	// SourceDetected: built-in detection fills the column.
	SourceDetected
	// SourceAdapter: an enabled adapter fills it.
	SourceAdapter
	// SourceAdapterEnv: the harness's own environment variable fills it.
	SourceAdapterEnv
)

// ContextField is one context column's precedence row: the flag, the
// SKILL_LOG_* variable, the flag's value description and the non-flag source
// that feed it. The table's order is the resolution order.
type ContextField struct {
	Column string
	Flag   string
	What   string
	Env    string
	Source ContextSource
}

// ContextFields is the precedence table, in resolution order: a column that
// feeds an adapter comes before the columns the adapter fills. The machine
// carries no variable: SKILL_LOG_MACHINE is inert.
func ContextFields() []ContextField {
	return []ContextField{
		{Column: "worktree", Flag: "--worktree", What: "a path", Env: "SKILL_LOG_WORKTREE", Source: SourceDetected},
		{Column: "session", Flag: "--session", What: "an id", Env: "SKILL_LOG_SESSION", Source: SourceAdapterEnv},
		{Column: "repo", Flag: "--repo", What: "a name", Env: "SKILL_LOG_REPO", Source: SourceDetected},
		{Column: "harness", Flag: "--harness", What: "a name", Env: "SKILL_LOG_HARNESS", Source: SourceAdapter},
		{Column: "model", Flag: "--model", What: "provider/id", Env: "SKILL_LOG_MODEL", Source: SourceAdapter},
		{Column: "project", Flag: "--project", What: "a name", Env: "SKILL_LOG_PROJECT", Source: SourceAdapter},
		{Column: "parent", Flag: "--parent", What: "an id", Env: "SKILL_LOG_PARENT", Source: SourceNone},
		{Column: "t3_thread", Flag: "--t3-thread", What: "an id", Env: "SKILL_LOG_T3_THREAD", Source: SourceNone},
		{Column: "machine", Flag: "--machine", What: "a name", Env: "", Source: SourceDetected},
	}
}

// firstPresent is the first value that is not blank, trimmed: a whitespace-only
// value counts as absent.
func firstPresent(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// ResolveContext fills every column: the explicit flag, then its SKILL_LOG_*
// variable, then an enabled adapter, then built-in detection. Adapters are
// opt-in and run once, after the columns that feed them are resolved.
func ResolveContext(flags map[string]string, adapterFlags []string, detected Detected) (Context, error) {
	adapters := EnabledAdapters(adapterFlags)
	var context Context
	// The adapters run once, over the columns resolved so far. The table puts
	// worktree and session first for exactly that reason; an adapter never
	// fills parent or t3_thread, and never its own inputs.
	var filled AdapterContext
	ran := false
	for _, field := range ContextFields() {
		value := firstPresent(flags[field.Column], EnvOrEmpty(field.Env))
		if value == "" {
			switch field.Column {
			case "worktree":
				value = firstPresent(detected.Worktree)
			case "session":
				// The harness's own variable is consulted only when the
				// adapter that owns it runs.
				if HasAdapter(adapters, "opencode") {
					value = firstPresent(EnvOrEmpty(OpenCodeSessionEnv))
				}
			case "repo":
				// The repo follows the resolved worktree: a caller-named one
				// may be another checkout, with its own origin.
				if context.Worktree == detected.Worktree {
					value = firstPresent(detected.Repo)
				} else {
					value = firstPresent(DetectRepo(context.Worktree))
				}
			case "harness", "model", "project":
				if !ran {
					filled = ApplyAdapters(adapters, context.Worktree, context.Session)
					ran = true
				}
				switch field.Column {
				case "harness":
					value = firstPresent(filled.Harness)
				case "model":
					value = firstPresent(filled.Model)
				case "project":
					value = firstPresent(filled.Project)
				}
			case "machine":
				// The machine is always this host's hostname; --machine names
				// it instead. A hostname that cannot be read is an error, not
				// an empty machine.
				name, err := Hostname()
				if err != nil {
					return Context{}, err
				}
				value = name
			}
		}
		context.assign(field.Column, value)
	}
	return context, nil
}

// assign stores one resolved column's value.
func (c *Context) assign(column, value string) {
	switch column {
	case "harness":
		c.Harness = value
	case "session":
		c.Session = value
	case "parent":
		c.Parent = value
	case "model":
		c.Model = value
	case "repo":
		c.Repo = value
	case "worktree":
		c.Worktree = value
	case "project":
		c.Project = value
	case "t3_thread":
		c.T3Thread = value
	case "machine":
		c.Machine = value
	}
}
