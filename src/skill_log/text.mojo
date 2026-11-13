"""The text rules: sanitizing, quoting, joining."""


def shell_quote(text: String) -> String:
    """`text` as one single-quoted shell word."""
    var out = "'"
    for c in text.codepoints():
        var ch = String(c)
        if ch == "'":
            out += "'\\''"
        else:
            out += ch
    out += "'"
    return out


def is_control(code: Int) -> Bool:
    """True when a code point is one the tool replaces."""
    if code == 9:
        return False
    if code < 0x20:
        return True
    return code == 0x7F


def sanitize(text: String) -> String:
    """`text` with every control character turned into a space."""
    var out = String("")
    for c in text.codepoints():
        var code = Int(c)
        if is_control(code):
            out += " "
        else:
            out += String(c)
    return out


def prefixed(lines: List[String]) -> String:
    """The lines as the stderr notes `main` prints, one prefix each."""
    var out = List[String]()
    for i in range(len(lines)):
        out.append("skill-log: " + lines[i])
    return "\n".join(out)
