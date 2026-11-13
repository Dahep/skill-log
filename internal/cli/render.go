package cli

import (
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/store"
)

// RenderRowJSON renders one invocation row as one flat JSON object.
//
// Every column of the row, in the schema's own order, then the marker and the
// problems. An id of zero means the row has not been written yet, and it is
// rendered as null so a --dry-run preview does not claim a row that does not
// exist.
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
		format.Str("marker", row.Marker()),
		format.Raw("problems", format.JSONStrings(row.Problems)),
	)
}
