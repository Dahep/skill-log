"""The table: fixed-width columns for a person."""

from std.os import getenv


def pad(text: String, width: Int) -> String:
    """`text` left-aligned in `width` code points."""
    var missing = width - text.count_codepoints()
    if missing <= 0:
        return text
    return text + " " * missing


def join_lines(lines: List[String]) -> String:
    """The lines, separated by newlines, with no trailing newline."""
    return "\n".join(lines)


def home_prefix() -> String:
    """The home directory with a trailing separator, or an empty string."""
    var home = getenv("HOME", "")
    if home == "":
        return ""
    if home.endswith("/"):
        return home
    return home + "/"


def shorten_home(path: String) -> String:
    """The path with the reader's home directory replaced by `~`."""
    var home = home_prefix()
    if home == "":
        return path
    if path.startswith(home):
        return "~/" + String(path[byte=home.byte_length():])
    return path
