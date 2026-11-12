package cli

import (
	"strconv"

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
	var out []byte
	if row.ID > 0 {
		out = append(out, `{"id":`+strconv.FormatInt(row.ID, 10)...)
	} else {
		out = append(out, `{"id":null`...)
	}
	out = append(out, `,"ts":`...)
	out = append(out, format.JSONString(row.TS)...)
	out = append(out, `,"skill":`...)
	out = append(out, format.JSONString(row.Skill)...)
	out = append(out, `,"harness":`...)
	out = append(out, format.JSONString(row.Harness)...)
	out = append(out, `,"session":`...)
	out = append(out, format.JSONString(row.Session)...)
	out = append(out, `,"parent":`...)
	out = append(out, format.JSONString(row.Parent)...)
	out = append(out, `,"model":`...)
	out = append(out, format.JSONString(row.Model)...)
	out = append(out, `,"repo":`...)
	out = append(out, format.JSONString(row.Repo)...)
	out = append(out, `,"worktree":`...)
	out = append(out, format.JSONString(row.Worktree)...)
	out = append(out, `,"project":`...)
	out = append(out, format.JSONString(row.Project)...)
	out = append(out, `,"t3_thread":`...)
	out = append(out, format.JSONString(row.T3Thread)...)
	out = append(out, `,"machine":`...)
	out = append(out, format.JSONString(row.Machine)...)
	out = append(out, `,"fix":`...)
	out = append(out, format.JSONString(row.Fix)...)
	out = append(out, `,"resolved_at":`...)
	out = append(out, format.JSONString(row.ResolvedAt)...)
	out = append(out, `,"marker":`...)
	out = append(out, format.JSONString(row.Marker())...)
	out = append(out, `,"problems":`...)
	out = append(out, format.JSONStrings(row.Problems)...)
	out = append(out, '}')
	return string(out)
}
