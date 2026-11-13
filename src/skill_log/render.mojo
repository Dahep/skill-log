"""The row's JSON shape, in one place.

`add --json` and `show --json` must describe a row the same way: the same
fields, in the same order, with the same types. Otherwise a consumer
that reads one of them cannot read the other, and the two verbs drift
apart the moment one of them gains a field.

So the shape lives here, once, and both verbs call it. The key order is
ADR-0002's column order — `id`, `ts`, `skill`, then the context columns,
then the resolution columns — followed by the two derived fields every
consumer needs and neither table stores: the row's `marker` and its
`problems`.

The output is one flat object per line. There is no nesting: a caller
piping the stream into `jq` should never have to reach into a wrapper.
"""

from skill_log.json import JsonObject
from skill_log.store import Invocation


def render_row_json(row: Invocation) -> String:
    """One invocation row as one flat JSON object.

    Every column of the row, in the schema's own order, then the marker
    and the problems. The `id` is a number; every other field is a
    string; the problems are an array of strings. An id of zero means
    the row has not been written yet, and it is rendered as `null` so a
    `--dry-run` preview does not claim a row that does not exist.
    """
    var out = JsonObject()
    if row.id > 0:
        out.put_int("id", row.id)
    else:
        out.put_null("id")
    out.put("ts", row.ts)
    out.put("skill", row.skill)
    out.put("harness", row.harness)
    out.put("session", row.session)
    out.put("parent", row.parent)
    out.put("model", row.model)
    out.put("repo", row.repo)
    out.put("worktree", row.worktree)
    out.put("project", row.project)
    out.put("t3_thread", row.t3_thread)
    out.put("machine", row.machine)
    out.put("fix", row.fix)
    out.put("resolved_at", row.resolved_at)
    out.put("marker", row.marker())
    out.put_strings("problems", row.problems)
    return out.render()
