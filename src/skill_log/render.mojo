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

from skill_log.json import json_string, json_string_array
from skill_log.store import Invocation


def render_row_json(row: Invocation) -> String:
    """One invocation row as one flat JSON object.

    Every column of the row, in the schema's own order, then the marker
    and the problems. The `id` is a number; every other field is a
    string; the problems are an array of strings. An id of zero means
    the row has not been written yet, and it is rendered as `null` so a
    `--dry-run` preview does not claim a row that does not exist.
    """
    var out = "{"
    if row.id > 0:
        out += "\"id\":" + String(row.id)
    else:
        out += "\"id\":null"
    out += ",\"ts\":" + json_string(row.ts)
    out += ",\"skill\":" + json_string(row.skill)
    out += ",\"harness\":" + json_string(row.harness)
    out += ",\"session\":" + json_string(row.session)
    out += ",\"parent\":" + json_string(row.parent)
    out += ",\"model\":" + json_string(row.model)
    out += ",\"repo\":" + json_string(row.repo)
    out += ",\"worktree\":" + json_string(row.worktree)
    out += ",\"project\":" + json_string(row.project)
    out += ",\"t3_thread\":" + json_string(row.t3_thread)
    out += ",\"machine\":" + json_string(row.machine)
    out += ",\"fix\":" + json_string(row.fix)
    out += ",\"resolved_at\":" + json_string(row.resolved_at)
    out += ",\"marker\":" + json_string(row.marker())
    out += ",\"problems\":" + json_string_array(row.problems)
    out += "}"
    return out
