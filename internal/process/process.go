// Package process is the one process boundary.
package process

import (
	"bytes"
	"errors"
	"os/exec"
	"strings"
)

type Result struct {
	Status int
	Stdout string
	Stderr string
}

// Run executes name with args in dir and captures both streams. An empty dir
// means the process's own working directory. A command that cannot start is -1.
func Run(dir, name string, args ...string) Result {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	result := Result{Stdout: stdout.String(), Stderr: stderr.String()}
	if err == nil {
		result.Status = 0
		return result
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.Status = exitErr.ExitCode()
		return result
	}
	result.Status = -1
	if result.Stderr == "" {
		result.Stderr = err.Error()
	}
	return result
}

type Cause int

const (
	// GitOk means the command ran and succeeded.
	GitOk Cause = iota
	// GitNotARepository means the directory is not inside a git checkout.
	GitNotARepository
	// GitNoCommits means the repository has no commits yet.
	GitNoCommits
	// GitMissing means git itself is not installed.
	GitMissing
	// GitFailed means git ran and failed for some other reason.
	GitFailed
)

type GitResult struct {
	Cause  Cause
	Out    string
	Status int
	Stderr string
}

// Git runs git with args in dir and classifies the outcome. The caller reads
// Cause and Out; it never decodes Stderr.
func Git(dir string, args ...string) GitResult {
	result := Run(dir, "git", args...)
	out := GitResult{
		Out:    strings.TrimSpace(result.Stdout),
		Status: result.Status,
		Stderr: result.Stderr,
	}
	if result.Status == 0 {
		out.Cause = GitOk
		return out
	}
	if result.Status < 0 {
		out.Cause = GitMissing
		return out
	}
	stderr := strings.ToLower(result.Stderr)
	switch {
	case strings.Contains(stderr, "not a git repository"):
		out.Cause = GitNotARepository
	case strings.Contains(stderr, "does not have any commits"),
		strings.Contains(stderr, "unknown revision"),
		strings.Contains(stderr, "bad revision"):
		out.Cause = GitNoCommits
	default:
		out.Cause = GitFailed
	}
	return out
}
