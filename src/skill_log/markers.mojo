"""The marker grammar: `machine#id`."""


def marker_text(machine: String, id: Int) -> String:
    """The canonical spelling of a marker: the machine, `#`, the id."""
    return machine + "#" + String(id)


struct Marker(Movable):
    """One parsed `machine#id` marker."""

    var machine: String
    var id: Int

    def __init__(out self, machine: String = "", id: Int = 0):
        self.machine = machine
        self.id = id

    def text(self) -> String:
        """The canonical spelling: the machine, `#`, the id in decimal."""
        return marker_text(self.machine, self.id)


def parse_marker(value: String) -> Optional[Marker]:
    """The marker `value` names, or `None`."""
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
