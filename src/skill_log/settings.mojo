"""Where the tool's files live, and which binary it is.

Three rules decide where the tool reads and writes, and they were
written out in two modules: the XDG state and config directories, the
store's own path, and the path of the binary itself. One module holds
them now, so a rule about a path lives in one place and every caller
gets the same answer.

The XDG rules are the standard ones:

- `XDG_STATE_HOME` first, else `$HOME/.local/state` — the store and
  the seeded-from record live here.
- `XDG_CONFIG_HOME` first, else `$HOME/.config` — the user's copies of
  the shipped templates live here.

The store's path is `--db` first, then `SKILL_LOG_DB`, then the XDG
state directory. The template directory is `--template-dir` first, then
`SKILL_LOG_TEMPLATE_DIR`, then the XDG config directory.

The binary's own path is the third rule: a bare name is looked up on
`PATH`, and whatever is found — or given — is resolved to one absolute,
symlink-free path. A name the filesystem cannot resolve is used as it
was given rather than dropped.
"""

from std.os import getenv
from std.pathlib import Path
from std.sys import argv

from skill_log.files import resolve_path

# The directory the tool's own files live under, inside the XDG state
# and config directories.
comptime STATE_DIR_NAME = "skill-log"

# The file name of the store, inside the XDG state directory.
comptime STORE_FILE_NAME = "skills.db"


# --------------------------------------------------------------- xdg paths


def xdg_state_home() -> String:
    """The XDG state directory, per the XDG rules.

    `XDG_STATE_HOME` first, else `$HOME/.local/state`.
    """
    var xdg = getenv("XDG_STATE_HOME", "")
    if xdg != "":
        return xdg
    return getenv("HOME", "") + "/.local/state"


def xdg_config_home() -> String:
    """The XDG config directory, per the XDG rules.

    `XDG_CONFIG_HOME` first, else `$HOME/.config`.
    """
    var xdg = getenv("XDG_CONFIG_HOME", "")
    if xdg == "":
        xdg = getenv("HOME", "") + "/.config"
    return xdg


def xdg_state_dir() -> String:
    """The skill-log state directory, per the XDG rules.

    The store lives beside this in `skills.db`; the seeded-from record
    lives in `seeded-from/` here.
    """
    return xdg_state_home() + "/" + STATE_DIR_NAME


def xdg_config_dir() -> String:
    """The user template directory, per the XDG rules.

    `XDG_CONFIG_HOME` first, else `$HOME/.config`. The templates are
    the `skill-log/templates/` directory inside it.
    """
    return xdg_config_home() + "/" + STATE_DIR_NAME + "/templates"


# --------------------------------------------------------------- the store


def expand_home(path: String) -> String:
    """Expand a leading `~` to the user's home.

    `~` alone is the home directory; `~/x` is `x` inside it. A path
    that does not start with `~` is returned unchanged.
    """
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
    """The store path when nothing overrides it.

    The XDG state directory, per the rules above. The directory is
    never created here: a read must not change the machine.
    """
    return xdg_state_dir() + "/" + STORE_FILE_NAME


def resolve_db(flag: String) -> String:
    """The store path: `--db` first, then `SKILL_LOG_DB`, then the default.

    An empty `--db` means the flag was not given, so the environment
    variable gets its turn.
    """
    if flag != "":
        return expand_home(flag)
    var env = getenv("SKILL_LOG_DB", "")
    if env != "":
        return expand_home(env)
    return default_db()


# -------------------------------------------------------------- templates


def default_template_dir() -> String:
    """The user template directory (source 3 in the resolution chain)."""
    return xdg_config_dir()


def resolve_template_dir(flag: String) -> String:
    """The effective template directory, by the spec's chain.

    `--template-dir` first, then `SKILL_LOG_TEMPLATE_DIR`, then the user
    config directory. The shipped defaults are a separate fallback: a
    directory that does not contain a given template name falls through
    to the shipped default for that name.
    """
    if String(flag.strip()) != "":
        return String(flag.strip())
    var env = getenv("SKILL_LOG_TEMPLATE_DIR", "")
    if String(env.strip()) != "":
        return String(env.strip())
    return default_template_dir()


# ----------------------------------------------------------- the binary


def find_in_path(program: String) -> String:
    """`program` as the first executable name on `PATH`, or unchanged.

    The shell's own first-match rule, for when the tool is invoked by
    bare name: `PATH` is walked left to right and the first entry that
    holds the file wins. A name `PATH` does not carry comes back as it
    went in — the caller still resolves it, and still falls back to the
    given name.
    """
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

    "The resolved binary path" is one answer no matter how the tool was
    invoked: a bare name is looked up on `PATH`, and whatever is found —
    or given — is resolved to one absolute, symlink-free path by
    `resolve_path`. A name the filesystem cannot resolve (a deleted
    binary, say) is used as it was given rather than dropped.
    """
    var all = argv()
    var program = String(all[0])
    if program.find("/") < 0:
        program = find_in_path(program)
    var real = resolve_path(program)
    if real != "":
        return real
    return program
