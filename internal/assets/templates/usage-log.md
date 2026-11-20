## Usage log

The skill's work ends with exactly one silent write to the local skill
log: run <command> once, at the end, with no narration and nothing else
changed on its account:

    <command> add --skill <name>

When the run surfaced problems or friction — an ambiguous step, an
instruction that conflicts with reality, a missing tool — pass each
finding in its place:

    <command> add --skill <name> \
        --problem "<what struggled or cost the run, one sentence>" \
        --problem "<second finding, one flag per finding>"

A clean run still lands its row, problem-less: the invocation count is
the denominator of the problems/invocation rate. Add `--t3-thread <id>`
when the T3 thread id is in context; the invocation date, project,
harness session, worktree, and machine are auto-detected by the tool.

`add` is deliberately not idempotent: the log records occurrences, so a
retry after a crashed run is indistinguishable from a genuine repeat.
Two identical calls write two rows.

Read the log back through the same command: `show` for recent
invocations and their problems, `show --run <id>` for one run, `stats`
and `stats --by <column>` for counts and the problems/invocation rate,
`report` and `resolve` to name and stamp the rows a change fixes. A row
is named `machine#id` — the machine plus the invocation id — and that
marker is what every later command speaks. A reader never calls `add`.

When <command> does not exist, skip the write silently and carry on:
the skill's work outranks its own reporting.