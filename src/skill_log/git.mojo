"""One seam for every git command the tool runs."""

from std.subprocess import run

from skill_log.text import shell_quote


struct GitResult(Movable):
    """What one git command produced."""

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
    """Run one git command in `dir` and report what it produced."""
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
    """The exact stdout of one git command, or an empty string."""
    return git(dir, args).stdout


def git_text(dir: String, args: String) -> String:
    """The trimmed stdout of one git command, or an empty string."""
    return git(dir, args).trimmed()


def git_toplevel(dir: String) -> String:
    """The working-tree root that contains `dir`, or an empty string."""
    return git_text(dir, "rev-parse --show-toplevel")


def git_branch(dir: String) -> String:
    """The current branch of the repository `dir` is in, or an empty string."""
    return git_text(dir, "rev-parse --abbrev-ref HEAD")


def git_common_dir(dir: String) -> String:
    """The repository's common git directory, or an empty string."""
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
    """The `origin` remote's URL of the repository `dir` is in, or empty."""
    return git_text(dir, "remote get-url origin")


def git_commit(dir: String, revision: String) -> String:
    """The commit `revision` names, or an empty string."""
    var args = "rev-parse --verify " + shell_quote(revision + "^{commit}")
    return git_text(dir, args)
