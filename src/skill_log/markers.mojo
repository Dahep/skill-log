"""The marker grammar: `machine#id`.

A marker is the only way a row is named from outside the store. The
machine is required because a store's ids are per store: `7` names a
different row on every machine, `boxA#7` names one row everywhere.

The grammar is strict on purpose. A bare id, a placeholder or a typo is
never guessed at — it is reported, because the resolution that reads it
would otherwise stamp the wrong row on some machine. The id is a positive
decimal: a sign, a space or a fraction is not an invocation id.

`add` writes the marker a row is named by; `report` writes markers to a
file; `resolve-merged` will parse them back. The spelling lives here so
all three agree.
"""

from skill_log.store import Invocation


struct Marker(Movable):
    """One parsed `machine#id` marker."""

    var machine: String
    var id: Int

    def __init__(out self, machine: String = "", id: Int = 0):
        self.machine = machine
        self.id = id

    def text(self) -> String:
        """The canonical spelling: the machine, `#`, the id in decimal."""
        return self.machine + "#" + String(self.id)


def marker_text(row: Invocation) -> String:
    """The marker a row is named by: its machine and its local id."""
    return row.machine + "#" + String(row.id)


def parse_marker(value: String) -> Optional[Marker]:
    """The marker `value` names, or `None`.

    The machine is everything before the first `#` and must be non-empty;
    the id is everything after it and must be a positive decimal. An
    oversized id is refused rather than wrapped, so nothing can parse
    into a valid-looking id that names nothing.
    """
    var text = String(value.strip())
    var cut = text.find("#")
    if cut <= 0 or cut == text.byte_length() - 1:
        return None
    var machine = String(String(text[byte=0:cut]).strip())
    if machine == "":
        return None
    var digits = String(text[byte=cut + 1:])
    var number = 0
    for c in digits.codepoints():
        var code = Int(c)
        if code < 48 or code > 57:
            return None
        number = number * 10 + (code - 48)
        if number > 2_000_000_000:
            return None
    if number < 1:
        return None
    var marker = Marker()
    marker.machine = machine
    marker.id = number
    return marker^
