"""The row's JSON shape, in one place.

`add --json` and `show --json` must describe a row the same way: the same
fields, in the same order, with the same types. Otherwise a consumer
that reads one of them cannot read the other, and the two verbs drift
apart the moment one of them gains a field.

So the shape lives here, once, and both verbs call it. The key order is
the schema's own column order — the one `store.mojo`'s column list
declares — followed by the two derived fields every consumer needs and
neither table stores: the row's `marker` and its `problems`.

Because the order comes from the column list rather than from a
hand-written list of keys here, a column added to the schema cannot be
missing from this shape, and this shape cannot carry a key the schema
does not have.

The output is one flat object per line. There is no nesting: a caller
piping the stream into `jq` should never have to reach into a wrapper.
"""

from skill_log.json import JsonObject
from skill_log.store import Invocation, invocation_columns


def render_row_json(row: Invocation) -> String:
    """One invocation row as one flat JSON object.

    Every column of the row, in the schema's own order, then the marker
    and the problems. The `id` is a number; every other field is a
    string; the problems are an array of strings. An id of zero means
    the row has not been written yet, and it is rendered as `null` so a
    `--dry-run` preview does not claim a row that does not exist.
    """
    var out = JsonObject()
    var columns = invocation_columns()
    for i in range(len(columns)):
        var name = columns[i].name
        if name == "id":
            if row.id > 0:
                out.put_int("id", row.id)
            else:
                out.put_null("id")
            continue
        out.put(name, row.text_column(name))
    out.put("marker", row.marker())
    out.put_strings("problems", row.problems)
    return out.render()
