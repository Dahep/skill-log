"""Text safety: the characters this tool neither stores nor prints raw.

The tool has one line-shaped contract in three places: a problem is one
line, a diagnostic is one line, and neither may carry a terminal escape.
All three are the same rule about the same byte set, so the rule lives in
one module instead of being re-derived per caller.

The set is the reference implementation's — C0 below 0x20 except tab, plus
DEL. Tab stays: a person means to type it. Everything else becomes a space,
which keeps the text readable and cannot start a new line.
"""


def is_control(code: Int) -> Bool:
    """True when a code point is one the tool replaces.

    C0 below 0x20 except tab, plus DEL.
    """
    if code == 9:
        return False
    if code < 0x20:
        return True
    return code == 0x7F


def sanitize(text: String) -> String:
    """`text` with every control character turned into a space.

    A newline becomes a space, so one problem stays one line and cannot
    inject a terminal escape, and a diagnostic carrying a path with a
    newline in it stays a diagnostic on one line.
    """
    var out = String("")
    for c in text.codepoints():
        var code = Int(c)
        if is_control(code):
            out += " "
        else:
            out += String(c)
    return out


def prefixed(lines: List[String]) -> String:
    """The lines as the stderr notes `main` prints, one prefix each.

    A verb's notes are already one line each; every one carries the same
    `skill-log: ` prefix as a failure, so a caller can recognise the
    tool's voice on stderr. An empty list produces no notes at all, so a
    clean run has no stderr line.
    """
    var out = List[String]()
    for i in range(len(lines)):
        out.append("skill-log: " + lines[i])
    return "\n".join(out)
