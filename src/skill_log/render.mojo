"""Rendering a row: the table's cells and the JSON shape."""

from skill_log.json import JsonObject
from skill_log.store import Invocation, invocation_columns


def render_row_json(row: Invocation) -> String:
    """One invocation row as one flat JSON object."""
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
