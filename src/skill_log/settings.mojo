"""The one module for where the tool's files live."""

from std.os import getenv
from std.pathlib import Path
from std.sys import argv

from skill_log.files import resolve_path

comptime STATE_DIR_NAME = "skill-log"

comptime STORE_FILE_NAME = "skills.db"




def xdg_state_home() -> String:
    """The XDG state directory, per the XDG rules."""
    var xdg = getenv("XDG_STATE_HOME", "")
    if xdg != "":
        return xdg
    return getenv("HOME", "") + "/.local/state"


def xdg_config_home() -> String:
    """The XDG config directory, per the XDG rules."""
    var xdg = getenv("XDG_CONFIG_HOME", "")
    if xdg == "":
        xdg = getenv("HOME", "") + "/.config"
    return xdg


def xdg_state_dir() -> String:
    """The skill-log state directory, per the XDG rules."""
    return xdg_state_home() + "/" + STATE_DIR_NAME


def xdg_config_dir() -> String:
    """The user template directory, per the XDG rules."""
    return xdg_config_home() + "/" + STATE_DIR_NAME + "/templates"




def expand_home(path: String) -> String:
    """Expand a leading `~` to the user's home."""
    if not path.startswith("~"):
        return path
    var home = getenv("HOME", "")
    if home == "":
        return path
    if path == "~":
        return home
    if path.startswith("~/"):
        return home + String(path[byte=1:])
    return path


def default_db() -> String:
    """The store path when nothing overrides it."""
    return xdg_state_dir() + "/" + STORE_FILE_NAME


def resolve_db(flag: String) -> String:
    """The store path: `--db` first, then `SKILL_LOG_DB`, then the default."""
    if flag != "":
        return expand_home(flag)
    var env = getenv("SKILL_LOG_DB", "")
    if env != "":
        return expand_home(env)
    return default_db()




def default_template_dir() -> String:
    """The user template directory (source 3 in the resolution chain)."""
    return xdg_config_dir()


def resolve_template_dir(flag: String) -> String:
    """The effective template directory, by the spec's chain."""
    if String(flag.strip()) != "":
        return String(flag.strip())
    var env = getenv("SKILL_LOG_TEMPLATE_DIR", "")
    if String(env.strip()) != "":
        return String(env.strip())
    return default_template_dir()




def find_in_path(program: String) -> String:
    """`program` as the first executable name on `PATH`, or unchanged."""
    var path = getenv("PATH", "")
    var start = 0
    var n = path.byte_length()
    while start <= n:
        var cut = path.find(":", start)
        if cut < 0:
            cut = n
        var entry = String(path[byte=start:cut])
        if entry != "":
            var candidate = entry + "/" + program
            if Path(candidate).is_file():
                return candidate
        start = cut + 1
    return program


def resolved_command() -> String:
    """The path of this binary, resolved: `<command>`'s value.

    The resolved path is what the rendered block names, so a binary that
    moved makes every block an older render.
    """
    var all = argv()
    var program = String(all[0])
    if program.find("/") < 0:
        program = find_in_path(program)
    var real = resolve_path(program)
    if real != "":
        return real
    return program
