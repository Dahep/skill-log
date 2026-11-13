package settings

import (
	"path/filepath"
	"strings"

	"github.com/Dahep/skill-log/internal/process"
)

// gitDir runs one constant git command in dir and returns its trimmed stdout. An
// empty string means the command failed, printed nothing, or git is missing.
func gitDir(dir string, args ...string) string {
	return process.Git(dir, args...).Out
}

func GitToplevel() string {
	return gitDir("", "rev-parse", "--show-toplevel")
}

// GitBranch is the current branch of the repository dir is in, or "". A detached
// HEAD answers `HEAD`, which names no report file.
func GitBranch(dir string) string {
	return gitDir(dir, "rev-parse", "--abbrev-ref", "HEAD")
}

func GitToplevelOf(dir string) string {
	if dir == "" {
		return ""
	}
	return gitDir(dir, "rev-parse", "--show-toplevel")
}

// GitCommonDir is the repository's common git directory, or "": the one every
// linked worktree shares. Older git answers with a path relative to dir.
func GitCommonDir(dir string) string {
	out := gitDir(dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if out != "" {
		return out
	}
	out = gitDir(dir, "rev-parse", "--git-common-dir")
	if out == "" || strings.HasPrefix(out, "/") || dir == "" {
		return out
	}
	return filepath.Join(dir, out)
}

func GitOriginURL(dir string) string {
	return gitDir(dir, "remote", "get-url", "origin")
}

// StripUserinfo removes any credentials from a remote URL. A URL whose `@` sits
// after the path's first `/` is returned unchanged, and so is an scp-style remote.
func StripUserinfo(url string) string {
	if !strings.HasPrefix(url, "http://") &&
		!strings.HasPrefix(url, "https://") &&
		!strings.HasPrefix(url, "ssh://") {
		return url
	}
	cut := strings.Index(url, "@")
	if cut == -1 {
		return url
	}
	schemeEnd := strings.Index(url, "//")
	slash := -1
	if schemeEnd != -1 {
		if rel := strings.Index(url[schemeEnd+2:], "/"); rel != -1 {
			slash = schemeEnd + 2 + rel
		}
	}
	if slash != -1 && slash < cut {
		return url
	}
	return url[cut+1:]
}

// produce an empty segment.
func Basename(path string) string {
	text := path
	for len(text) > 1 && strings.HasSuffix(text, "/") {
		text = text[:len(text)-1]
	}
	cut := strings.LastIndex(text, "/")
	if cut == -1 {
		return text
	}
	if cut == len(text)-1 {
		return ""
	}
	return text[cut+1:]
}

// RepoName is the repository name an origin URL names: the last path segment,
// without the `.git` suffix. An scp-style remote separates on the colon.
func RepoName(url string) string {
	if url == "" {
		return ""
	}
	text := url
	colon := strings.LastIndex(text, ":")
	if colon != -1 {
		slash := strings.LastIndex(text, "/")
		if slash == -1 || colon > slash {
			text = text[colon+1:]
		}
	}
	name := Basename(text)
	if strings.HasSuffix(name, ".git") {
		name = name[:len(name)-4]
	}
	return name
}

// DetectRepo is the repository the named worktree belongs to: the origin
// remote's basename, or the directory's own name as fallback.
func DetectRepo(top string) string {
	if top == "" {
		return ""
	}
	if GitToplevelOf(top) == "" {
		return ""
	}
	if name := RepoName(StripUserinfo(GitOriginURL(top))); name != "" {
		return name
	}
	return Basename(top)
}

func DetectWorktree() string {
	return GitToplevel()
}

func t3Home() string {
	if home := EnvOrEmpty("T3CODE_HOME"); home != "" {
		return home
	}
	return EnvOrEmpty("HOME") + "/.t3"
}

// T3Project is the T3 project grouping of a worktree: the first path segment
// under $T3CODE_HOME/worktrees/, or "". One is never invented.
func T3Project(worktree string) string {
	if worktree == "" {
		return ""
	}
	prefix := t3Home() + "/worktrees/"
	if !strings.HasPrefix(worktree, prefix) {
		return ""
	}
	rest := worktree[len(prefix):]
	if rest == "" {
		return ""
	}
	if cut := strings.Index(rest, "/"); cut != -1 {
		return rest[:cut]
	}
	return rest
}
