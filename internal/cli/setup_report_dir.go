package cli

// The report directory's README and keep file, which `setup` creates with the
// directory and never touches again.
const (
	// reportReadmeName is the operator's one-page explanation of the transport.
	reportReadmeName = "README.md"
	// reportKeepName keeps the directory in the tree when it holds no report.
	reportKeepName = ".keep"
)

func reportDirReadme() string {
	return `# .skill-log/reports

The report a change commits when it fixes friction recorded in the local
skill log. Resolution reads it after the merge, so the fix cannot be
forgotten.

- ` + "`" + `<slug>.md` + "`" + ` — one report per fix change, one ` + "`" + `machine#id` + "`" + ` per line.
  ` + "`" + `skill-log report --id …` + "`" + ` writes it (and validates the ids against the
  local log); commit it with the change.
- ` + "`" + `resolve-merged` + "`" + ` (the ` + "`" + `post-merge` + "`" + ` hook) reads the files a pull added or
  changed and stamps each named row with the commit that carries it. Each
  machine resolves only the rows it owns; a row named for another machine
  is reported there and resolves on that machine's next pull.

A repo without this directory still uses the commit-body
` + "`" + `Skill-log-Fix:` + "`" + ` trailer. This directory is the transport for repos that
have it, because a squash merge keeps tree content exactly as committed.
`
}
