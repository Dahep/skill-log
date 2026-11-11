# Usage log boilerplate

Every skill a run of [create-skill](../SKILL.md) authors carries the **Usage log** section below, verbatim, with its two `<name>` slots filled in. It is the single source of the wording: one row is written per skill invocation to the local SQLite log (`~/.local/state/skill-log/skills.db`, via `~/bin/skill-log`), a clean run's row has no problems, and problems reference the invocation that produced them — so `~/bin/skill-log stats` reads the problems/invocation rate straight off.

---

## Usage log

The skill's work ends with exactly one silent write to the local skill log:
run `~/bin/skill-log` once, at the end, with no narration and nothing else
changed on its account:

    ~/bin/skill-log add --skill <name>

When the run surfaced problems or friction — an ambiguous step, an instruction
that conflicts with reality, a missing tool — pass each finding in its
place:

    ~/bin/skill-log add --skill <name> \
        --problem "<what struggled or cost the run, one sentence>" \
        --problem "<second finding, one flag per finding>"

A clean run still lands its row, problem-less: the invocation count is the
denominator of the problems/invocation rate. Add `--t3-thread <id>` when the
T3 thread id is in context; the invocation date, project, opencode thread id,
worktree, and machine are auto-detected by the tool. When `~/bin/skill-log`
does not exist, skip the write silently and carry on: the skill's work
outranks its own reporting.

---

## Subagent error rider

When the skill dispatches subagents, **every dispatch brief ends with the
error rider below, verbatim in substance** — the dispatching skill's own
name in `<name>`, the role noun adapted to the brief's reader (reviewer,
explorer, judge, probe, candidate), and the allow-list/skip sentences
inside or after the block; no other variation is legal: the error
semantics, the command shape, and the silence rule never change.

> Error rider (silent, shape fixed): on any run-costing error — a failed
> tool call, a missing expected artifact, a dispatch or seat error — the
> subagent closes its run by inserting one row, one
> `--problem "<one sentence>"` per finding (plain text: no `"` in the
> sentence, no `$` or backticks, nothing starting with `-`), and narrates
> nothing in its reply:
>
>     ~/bin/skill-log add --skill <name> \
>         --parent "<parent T3 thread id>" \
>         --problem "<first finding>" \
>         --problem "<second finding, one flag per finding>"
>
> Pass `--parent "<parent T3 thread id>"` when the parent thread id is in
> context: dispatched rows share it, so one thread's rows coalesce for
> dedupe.

Row semantics: the insert creates one invocation row for the subagent run
and its problems land on that row, with `--model` auto-detected from the
subagent's own session — so a run with errors adds at most one invocation
per error-carrying dispatch instead of one per error. `--parent` (the
dispatching run's T3 thread id, when the parent knows it) ties the
dispatch-tree rows together for dedupe — and dedupe is an **analysis-time
read** (the parent column), never a logging decision: when the same
error surfaces both in a subagent's row and in the parent run's row,
both rows are correct to write, and any coalescing happens when someone
reads the log. When the subagent cannot run the write
(missing binary, refused command), it skips the row silently and
narrates nothing instead. The command's path is allow-listed
in `opencode.json` (`~/bin/skill-log *`), so a runner seat whose def
denies generic shell can still run exactly this insert — the seat defs
carry this one exception in their prose.

The dispatcher fills `<parent T3 thread id>` at compose time — its own
T3 thread id, resolved through the `t3code-session-id` skill when in
doubt — and stamps the value into the rider text it sends. A subagent
whose brief arrived without the id omits the `--parent` line; the row
still lands with an empty parent.

This is the single source of the wording, the same rule the Usage log
section follows: skills copy it into their dispatch steps or brief
templates, filling the skill name and adapting the recipient noun; error
semantics, command shape, and silence never vary.
