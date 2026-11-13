"""Built-in detection: the facts a row carries when nobody says otherwise."""

from std.os import getenv

from skill_log import text as text_module
from skill_log.git import git_origin_url, git_toplevel

# The directory T3 keeps its worktrees in, relative to the T3 home.
comptime T3_WORKTREES_DIR = "worktrees"


def env_or_empty(name: String) -> String:
    """The value of an environment variable, or an empty string.

    An unset variable and an empty one are the same thing to every
    caller here: the field is simply not filled.
    """
    return getenv(name, "")


def shell_quote(text: String) -> String:
    """`text` as one single-quoted shell word.

        A path the caller named reaches a shell command string, so it is
        quoted the one way a POSIX shell always reads back literally."""
    return text_module.shell_quote(text)


def strip_userinfo(url: String) -> String:
    """A remote URL with any credentials removed.

        An scp-style remote (`git@host:owner/repo.git`) is returned
        unchanged: its `git` is the login name in the host position."""
    if not url.startswith("http://") and not url.startswith("https://") \
            and not url.startswith("ssh://"):
        return url

    var cut = url.find("@")
    if cut == -1:
        return url

    # The userinfo is only userinfo when it sits before the path. The
    # scheme's own `//` does not count: the path starts after it.
    var scheme_end = url.find("//")
    var slash = url.find("/", scheme_end + 2)
    if slash != -1 and slash < cut:
        return url

    var rest = url[byte=cut + 1:]
    var stripped = String(rest)
    return stripped


def basename(path: String) -> String:
    """The last path segment of `path`.

    A trailing separator does not produce an empty segment: the
    directory's own name is what a caller wants.
    """
    var text = path
    while text.endswith("/") and text.byte_length() > 1:
        var shorter = text.byte_length() - 1
        var part = text[byte=0:shorter]
        var trimmed = String(part)
        text = trimmed
    var cut = text.rfind("/")
    if cut == -1:
        return text
    if cut == text.byte_length() - 1:
        return ""
    var tail = text[byte=cut + 1:]
    return String(tail)


def repo_name(url: String) -> String:
    """The repository name an origin URL names.

        The last path segment, without the `.git` suffix."""
    if url == "":
        return ""

    var text = url
    # An scp-style remote: `git@host:owner/repo.git`.
    var colon = text.rfind(":")
    if colon != -1:
        var slash = text.rfind("/")
        if slash == -1 or colon > slash:
            var scp_part = text[byte=colon + 1:]
            var scp_text = String(scp_part)
            text = scp_text

    var name = basename(text)
    if name.endswith(".git"):
        var shorter = name.byte_length() - 4
        var git_part = name[byte=0:shorter]
        var bare = String(git_part)
        name = bare
    return name


def detect_repo(top: String) -> String:
    """The repository the named worktree belongs to.

        Empty when `top` is not a git working tree. A path that is not a
        checkout names no repository, and one is never invented from the
        directory's name alone."""
    if top == "":
        return ""
    if git_toplevel(top) == "":
        return ""

    var name = repo_name(strip_userinfo(git_origin_url(top)))
    if name != "":
        return name
    return basename(top)


def detect_worktree() -> String:
    """The working-tree root, or an empty string outside a repository."""
    return git_toplevel("")


def t3_home() -> String:
    """The T3 home directory.

    `T3CODE_HOME` wins; `$HOME/.t3` is the fallback.
    """
    var home = getenv("T3CODE_HOME", "")
    if home != "":
        return home
    return getenv("HOME", "") + "/.t3"


def t3_project(worktree: String) -> String:
    """The T3 project grouping of a worktree.

        The first path segment under `$T3CODE_HOME/worktrees/`, or an empty
        string when the worktree is not under it."""
    if worktree == "":
        return ""

    var prefix = t3_home() + "/" + T3_WORKTREES_DIR + "/"
    if not worktree.startswith(prefix):
        return ""

    var rest = String(worktree[byte=prefix.byte_length():])
    if rest == "":
        return ""

    var cut = rest.find("/")
    if cut == -1:
        return rest
    return String(rest[byte=0:cut])
