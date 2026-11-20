package cli

import (
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

func rowMarker(machine string, id int64) string {
	if id <= 0 {
		return ""
	}
	if machine == "" {
		host, err := settings.Hostname()
		if err != nil {
			return "#" + formatInt(id)
		}
		machine = host
	}
	return marker.Format(machine, id)
}

// RenderRowJSON renders one invocation as a flat JSON object.
func RenderRowJSON(row store.Invocation) string {
	id := format.Raw("id", "null")
	if row.ID > 0 {
		id = format.Int("id", row.ID)
	}
	return format.Object(
		id,
		format.Str("ts", row.TS),
		format.Str("skill", row.Skill),
		format.Str("harness", row.Harness),
		format.Str("session", row.Session),
		format.Str("parent", row.Parent),
		format.Str("model", row.Model),
		format.Str("repo", row.Repo),
		format.Str("worktree", row.Worktree),
		format.Str("project", row.Project),
		format.Str("t3_thread", row.T3Thread),
		format.Str("machine", row.Machine),
		format.Str("fix", row.Fix),
		format.Str("resolved_at", row.ResolvedAt),
		format.Str("marker", rowMarker(row.Machine, row.ID)),
		format.Raw("problems", format.JSONStrings(row.Problems)),
	)
}
