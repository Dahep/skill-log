"""Built-in detection: the facts a row carries when nobody says otherwise.

ADR-0002 puts four fields outside the caller's control:

| Field | Built-in source |
|---|---|
| `repo` | the origin remote's basename, else the toplevel directory's name |
| `worktree` | `git rev-parse --show-toplevel` |
| `project` | the T3 worktree segment, when the worktree is under T3 |
| `machine` | the hostname |

Only `project` needs an adapter for its T3 grouping, and the adapter that
fills it is opt-in; the detection below is the built-in half of that
adapter's rule, kept here so the rule lives in one place.

Everything here degrades to an empty string rather than raising. A row
that says "unknown" is a useful row; a failed write is not.

The git calls go through `std.subprocess.run`, which takes a command
string and returns its stdout. The arguments of each are *constants*; the
only thing a caller supplies is a directory, which is passed with
`git -C` and shell-quoted (`shell_quote`), so a path can never be read as
a command. Both calls redirect stderr to `/dev/null`, so a repository
without an origin remote stays quiet. An empty result means "not a
repository" or "no origin", which is exactly the signal the callers want.

`repo` is resolved *from the worktree the row carries*, not from the
process's current directory: a caller that names `--worktree` gets the
repository of that checkout, so the two fields always describe the same
one.
"""

from std.os import getenv
from std.subprocess import run

# The arguments of the two git commands the detection uses. They are
# constants on purpose: the command string is passed to a shell, so only
# the directory — quoted — may vary.
comptime GIT_TOPLEVEL_ARGS = "rev-parse --show-toplevel"
comptime GIT_ORIGIN_ARGS = "remote get-url origin"
comptime GIT_BRANCH_ARGS = "rev-parse --abbrev-ref HEAD"

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
    quoted the one way a POSIX shell always reads back literally: single
    quotes, with an embedded single quote closed, escaped and re-opened.
    """
    var out = "'"
    for c in text.codepoints():
        var ch = String(c)
        if ch == "'":
            out += "'\\''"
        else:
            out += ch
    out += "'"
    return out


def run_git(dir: String, args: String) -> String:
    """Run one constant git command in `dir` and return its trimmed stdout.

    `args` is a constant from this module. `dir` is the one part of the
    command a caller supplies, and it is quoted. An empty `dir` means the
    process's own directory.

    An empty string means the command failed or printed nothing: git is
    missing, the directory is not a repository, or the remote does not
    exist. None of those is an error.
    """
    var command = "git "
    if dir != "":
        command += "-C " + shell_quote(dir) + " "
    command += args + " 2>/dev/null"
    try:
        var out = run(command)
        return String(out.strip())
    except:
        return ""


def git_toplevel() -> String:
    """The working-tree root of the current directory, or an empty string.

    `git rev-parse --show-toplevel` answers with the root of the current
    worktree, so a linked worktree (`git worktree add`) reports its own
    directory and not the main checkout's.
    """
    return run_git("", GIT_TOPLEVEL_ARGS)


def git_branch(dir: String) -> String:
    """The current branch of the repository `dir` is in, or an empty string.

    A detached HEAD answers `HEAD`, which names no report file; the
    caller refuses it and asks for `--slug`. Outside a repository the
    answer is empty.
    """
    return run_git(dir, GIT_BRANCH_ARGS)


def git_toplevel_of(dir: String) -> String:
    """The working-tree root that contains `dir`, or an empty string."""
    if dir == "":
        return ""
    return run_git(dir, GIT_TOPLEVEL_ARGS)


def git_origin_url(dir: String) -> String:
    """The `origin` remote's URL of the repository `dir` is in, or empty.

    Empty when `dir` is not a repository, or when it has no `origin`
    remote.
    """
    return run_git(dir, GIT_ORIGIN_ARGS)


def strip_userinfo(url: String) -> String:
    """A remote URL with any credentials removed.

    `https://user:token@host/owner/repo.git` becomes
    `host/owner/repo.git`, and `ssh://user@host/owner/repo.git` becomes
    `host/owner/repo.git`. A URL without userinfo is returned unchanged,
    and so is one whose `@` sits after the path's first `/` — that is a
    path segment, not a credential separator.

    An scp-style remote (`git@host:owner/repo.git`) is returned
    unchanged: its `git` is the login name in the host position, not a
    credential, and the basename below discards the host anyway.
    """
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

    The last path segment, without the `.git` suffix. An scp-style
    remote (`git@host:owner/repo.git`) has no `/` in its path part, so
    the colon is treated as the separator too.
    """
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

    `top` is the worktree the row will carry: the `--worktree` flag, its
    variable, or the detected toplevel. The origin remote's basename is
    the name; the directory's own name is the fallback when the
    repository has no origin remote.

    Empty when `top` is not a git working tree. A path that is not a
    checkout names no repository, and one is never invented from the
    directory's name alone.
    """
    if top == "":
        return ""
    if git_toplevel_of(top) == "":
        return ""

    var name = repo_name(strip_userinfo(git_origin_url(top)))
    if name != "":
        return name
    return basename(top)


def detect_worktree() -> String:
    """The working-tree root, or an empty string outside a repository."""
    return git_toplevel()


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
    string when the worktree is not under it. A worktree outside T3 has
    no project grouping, and one is never invented.
    """
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
