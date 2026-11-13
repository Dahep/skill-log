"""The one git seam.

Every git call the tool makes goes through here. Two modules used to
each have their own wrapper — `detect.mojo`'s `run_git` and
`merged.mojo`'s `git_output`/`git_commit` — and they differed only in
whether they trimmed stdout. One seam now, with the trimming as an
explicit part of the answer rather than a difference between two
functions.

The command is built from constants and shell-quoted values, and
stderr is redirected to `/dev/null`, so a repository without an origin
remote, a range git cannot read, or a directory that is not a checkout
all stay quiet: the answer is an empty string, not noise.

`std.subprocess.run` cannot report an exit status — it returns the
process's stdout and raises only when the process could not be started
at all. So `GitResult.status` is -1 whenever the status is unknown, and
a caller that needs to know whether git succeeded must decide what an
unknown status means. Nothing in the tool does: every caller wants the
output, and an empty output is the answer for "not a repository" as
well as for "git could not answer".
"""

from std.subprocess import run

from skill_log.text import shell_quote


struct GitResult(Movable):
    """What one git command produced.

    `status` is the exit status when it is known and -1 when it is not.
    `std.subprocess.run` cannot report one, so -1 is the honest answer
    for every command this tool runs — the field is here because a
    caller may want to say "unknown" rather than "zero".
    """

    var status: Int
    var stdout: String
    var stderr: String

    def __init__(out self, stdout: String = "", stderr: String = "", status: Int = -1):
        self.status = status
        self.stdout = stdout
        self.stderr = stderr

    def trimmed(self) -> String:
        """The stdout without its surrounding whitespace."""
        return String(self.stdout.strip())


def git(dir: String, args: String) -> GitResult:
    """Run one git command in `dir` and report what it produced.

    `args` is a constant from the calling module. `dir` is the one part
    a caller supplies, and it is quoted, so a path can never be read as
    a command. An empty `dir` means the process's own directory.

    A command that could not be run at all — git is missing, the
    directory does not exist — is an empty result rather than an
    exception: git being absent is not an error for a tool that only
    wants to know a repository's name.
    """
    var command = "git "
    if dir != "":
        command += "-C " + shell_quote(dir) + " "
    command += args + " 2>/dev/null"
    try:
        var out = run(command)
        return GitResult(String(out), "", -1)
    except:
        return GitResult()


def git_output(dir: String, args: String) -> String:
    """The exact stdout of one git command, or an empty string.

    The bytes are as git wrote them: a caller that splits the output
    into fields needs the separators to be where git put them.
    """
    return git(dir, args).stdout


def git_text(dir: String, args: String) -> String:
    """The trimmed stdout of one git command, or an empty string.

    The trimmed form is what a caller wants when it wants a value: a
    path, a branch name, a revision.
    """
    return git(dir, args).trimmed()


def git_toplevel(dir: String) -> String:
    """The working-tree root that contains `dir`, or an empty string.

    `git rev-parse --show-toplevel` answers with the root of the current
    worktree, so a linked worktree (`git worktree add`) reports its own
    directory and not the main checkout's.
    """
    return git_text(dir, "rev-parse --show-toplevel")


def git_branch(dir: String) -> String:
    """The current branch of the repository `dir` is in, or an empty string.

    A detached HEAD answers `HEAD`, which names no report file; the
    caller refuses it and asks for `--slug`. Outside a repository the
    answer is empty.
    """
    return git_text(dir, "rev-parse --abbrev-ref HEAD")


def git_common_dir(dir: String) -> String:
    """The repository's common git directory, or an empty string.

    The common directory is the one every linked worktree shares — the
    main repository's `.git` — and it is where the hooks directory
    belongs. A worktree's own `worktrees/<name>` directory is per-checkout
    state and git never looks there for hooks.

    Older git without `--path-format` answers with a path relative to
    `dir`; it is joined back onto `dir` so the caller always gets a path
    it can open.
    """
    var out = git_text(dir, "rev-parse --path-format=absolute --git-common-dir")
    if out != "":
        return out
    out = git_text(dir, "rev-parse --git-common-dir")
    if out == "" or out.startswith("/"):
        return out
    if dir == "":
        return out
    return dir + "/" + out


def git_origin_url(dir: String) -> String:
    """The `origin` remote's URL of the repository `dir` is in, or empty.

    Empty when `dir` is not a repository, or when it has no `origin`
    remote.
    """
    return git_text(dir, "remote get-url origin")


def git_commit(dir: String, revision: String) -> String:
    """The commit `revision` names, or an empty string.

    This is the bound check: a reflog position that does not exist is
    not an error here, it is a missing bound, and the caller falls back
    to a full scan.
    """
    var args = "rev-parse --verify " + shell_quote(revision + "^{commit}")
    return git_text(dir, args)
