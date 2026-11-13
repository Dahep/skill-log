"""The one JSON writer."""

# The seven characters JSON requires escaped: the quotation mark, the
# backslash, and the five control characters that have a short escape
# (`\n`, `\r`, `\t`, `\b`, `\f`).
#
# JSON *allows* one more escape — `\/` for the solidus — but does not
# require it, and this writer does not emit it: the solidus is not a
# character the grammar reserves.
#
# Two parallel lists rather than pairs: Mojo 1.2 cannot index a tuple
# with a runtime index, and the escape loop needs one. They are built
# per call rather than kept in a global, because Mojo has no globals
# and a `comptime` list of strings cannot be materialised at runtime.
def escape_chars() -> List[String]:
    """The characters JSON reserves."""
    var chars = List[String]()
    chars.append("\"")
    chars.append("\\")
    chars.append("\n")
    chars.append("\r")
    chars.append("\t")
    chars.append("\b")
    chars.append("\f")
    return chars^


def escape_replacements() -> List[String]:
    """The JSON escape each reserved character becomes."""
    var replacements = List[String]()
    replacements.append("\\\"")
    replacements.append("\\\\")
    replacements.append("\\n")
    replacements.append("\\r")
    replacements.append("\\t")
    replacements.append("\\b")
    replacements.append("\\f")
    return replacements^


def escape_string(text: String) -> String:
    """One JSON string literal, quotes included.

    Every character the JSON grammar reserves is escaped; everything
    else is copied through, so a problem's own words survive intact.
    """
    var chars = escape_chars()
    var replacements = escape_replacements()
    var out = "\""
    for c in text.codepoints():
        var ch = String(c)
        var replaced = False
        for i in range(len(chars)):
            if ch == chars[i]:
                out += replacements[i]
                replaced = True
                break
        if replaced:
            continue
        var code = Int(c)
        if code < 0x20:
            out += "\\u" + hex4(code)
        else:
            out += ch
    out += "\""
    return out


def hex4(code: Int) -> String:
    """Four lowercase hex digits for a code point below 0x10000."""
    var digits = "0123456789abcdef"
    var out = String("")
    for shift in [12, 8, 4, 0]:
        var nibble = (code >> shift) & 0xF
        var i = 0
        for c in digits.codepoints():
            if i == nibble:
                out += String(c)
                break
            i += 1
    return out


def json_string(text: String) -> String:
    """A JSON string value, quotes included."""
    return escape_string(text)


def json_string_array(items: List[String]) -> String:
    """A JSON array of strings."""
    var out = "["
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += escape_string(items[i])
    out += "]"
    return out


def json_bool(value: Bool) -> String:
    """A JSON boolean."""
    if value:
        return "true"
    return "false"


def json_number(value: Int) -> String:
    """A JSON number, as a whole number.

    The only numbers the tool writes are counts and ids, both integers,
    so there is no float formatting rule to get wrong.
    """
    return String(value)


def json_null() -> String:
    """The JSON null literal."""
    return "null"


struct JsonObject(Movable):
    """One JSON object, built in the order its keys are handed in.

    Every site that writes a JSON object used to concatenate its keys by
    hand, and a hand-concatenated object is where a missing comma or an
    unescaped value comes from. The builder owns the punctuation: the
    braces, the commas, the quotes and the escaping, so a caller only
    says which key holds which value.

    The key order is the order the keys are added, because the order is
    part of what the tool emits: a consumer that reads one object must
    read the next one the same way.

    A raw value is one the caller has already rendered — a number, a
    ratio like `1.25`, or `null` — and is inserted verbatim. Everything
    else is escaped here.
    """

    var parts: List[String]

    def __init__(out self):
        self.parts = List[String]()

    def put(mut self, key: String, value: String):
        """One string value under `key`."""
        self.parts.append(escape_string(key) + ":" + escape_string(value))

    def put_bool(mut self, key: String, value: Bool):
        """One boolean value under `key`."""
        self.parts.append(escape_string(key) + ":" + json_bool(value))

    def put_int(mut self, key: String, value: Int):
        """One whole number under `key`."""
        self.parts.append(escape_string(key) + ":" + json_number(value))

    def put_null(mut self, key: String):
        """A null value under `key`."""
        self.parts.append(escape_string(key) + ":" + json_null())

    def put_raw(mut self, key: String, value: String):
        """One already-rendered value under `key`.

        The value is inserted as it is: the caller has rendered it, and
        the builder does not second-guess it. A number and a `null` are
        the two raw values the tool writes.
        """
        self.parts.append(escape_string(key) + ":" + value)

    def put_strings(mut self, key: String, items: List[String]):
        """One array of strings under `key`."""
        self.parts.append(escape_string(key) + ":" + json_string_array(items))

    def render(mut self) -> String:
        """The finished object: `{...}`, with no trailing newline."""
        var out = "{"
        for i in range(len(self.parts)):
            if i > 0:
                out += ","
            out += self.parts[i]
        out += "}"
        return out
