"""A hand-rolled JSON writer.

The CLI writes JSON and never reads it, so the tool needs a writer and
not a parser. This is that writer: one flat object per line, a stable
key order (the order the keys are handed in), and correct escaping of
quotes, backslashes and control characters.

The output is UTF-8. A control character below 0x20 becomes its JSON
short escape where one exists (`\\n`, `\\t`, ...) and `\\u00xx` otherwise.
Every other character is passed through unchanged, so the text the user
wrote is the text that comes back out.
"""

# The six characters JSON requires escaped, plus the two that are only
# legal escaped.
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
