"""One seam for every git command the tool runs."""

from std.subprocess import run

from skill_log.text import shell_quote


def git(dir: String, args: String) -> String:
    """Run one git command in `dir`, returning its stdout ("" on failure)."""
    var command = "git "
    if dir != "":
        command += "-C " + shell_quote(dir) + " "
    command += args + " 2>/dev/null"
    try:
        return String(run(command))
    except:
        return ""


def git_text(dir: String, args: String) -> String:
    """The trimmed stdout of one git command, or an empty string."""
    return String(git(dir, args).strip())


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
