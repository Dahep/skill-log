"""The small pieces every printed table shares.

Two verbs print a table — `show` and `stats` — and both need the same
three things: a column padded to the width of its widest cell, the lines
joined without a trailing newline, and a worktree path with the reader's
home written as `~`. None of them is specific to a verb, so none of them
belongs in one.

There is no column-count or layout machinery here on purpose: the two
tables have different columns and different cells, and a shared layout
engine would be more code than the two renderers it replaced.
"""

from std.os import getenv


def pad(text: String, width: Int) -> String:
    """`text` left-aligned in `width` code points.

    Width is measured in code points, not bytes: a skill named `café`
    must not shove the column to its right over by one space.
    """
    var missing = width - text.count_codepoints()
    if missing <= 0:
        return text
    return text + " " * missing


def join_lines(lines: List[String]) -> String:
    """The lines, separated by newlines, with no trailing newline.

    `main` prints the text and adds the one newline the output needs, so
    a newline here would leave a blank line behind.
    """
    return "\n".join(lines)


def home_prefix() -> String:
    """The home directory with a trailing separator, or an empty string.

    An empty home yields an empty prefix, so no path is ever shortened
    against a home the machine does not have.
    """
    var home = getenv("HOME", "")
    if home == "":
        return ""
    if home.endswith("/"):
        return home
    return home + "/"


def shorten_home(path: String) -> String:
    """The path with the reader's home directory replaced by `~`.

    A path outside the home is returned unchanged. The home is the one
    the reader's own environment names, so the same row reads the same
    way for every reader on the machine.
    """
    var home = home_prefix()
    if home == "":
        return path
    if path.startswith(home):
        return "~/" + String(path[byte=home.byte_length():])
    return path
