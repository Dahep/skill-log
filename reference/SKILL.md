---
name: skill-log
description: Read the local skill invocation log — usage counts and the problems/friction tied to each skill's runs. Use when the user asks about skill usage, skill friction, "skill log", "problems per skill", or "which skills cause trouble". Writing a row is every skill's own Usage log section, not this skill; authoring or revising skills is create-skill.
---
<!-- rider-exempt: documents the dispatched-row column; reads and writes rows, dispatches nothing -->

# Skill log

Every skill invocation ends with one row in the local SQLite log: invocation
date, skill, model, T3 project, T3 thread id, opencode thread id, worktree,
machine — and problem rows tying to the invocation that found them. The CLI
owns the db (`~/bin/skill-log`); query it through the CLI, never the db by
hand. The model column is auto-detected at add time from the row's own
session id, read out of this machine's opencode session store — a session
that lives on another machine cannot be read from here and lands blank;
`--model` fills it when the caller knows.

## Reading

- Recent invocations, problems indented under each: `~/bin/skill-log show`
- One skill's history: `~/bin/skill-log show --skill <name> --last 5`
- Pipes and jq: `~/bin/skill-log show --last 50 --json | jq '.skill'`
- Dispatched rows (the rider's `--parent`): `~/bin/skill-log show --last
  50 --json | jq -c 'select(.parent != "")'` — the table renders the
  column too; blank means a parent-run row or a pre-`parent`-column row.
- Counts and rate: `~/bin/skill-log stats` — the problems/invocation column
  is the friction-per-use signal the user asks about.
- Cut by model (the rotation view — friction per model rather than per
  skill): `~/bin/skill-log stats --by-model`; show's JSON carries `model`
  too, so per-model history is `show --last 50 --json | jq -c 'select(.model != "")'`
  — blank means either no model was recorded (pre-migration rows, or a
  read-only snapshot copy that never migrated) or the session store could
  not answer; report it as a gap rather than treating it as a model row.
- Cut by host in an aggregated log: `~/bin/skill-log show --machine <host>`;
  the table's `machine` column names each row's owning host.

Every command accepts `--db <path>` for scratch copies and snapshot reads.
Done when the user's question is answered from CLI output, and any follow-up
friction question ("which of these runs struggled?") is answered from the same
rows.

## Resolving

A row is marked resolved by a later, separate step: `resolve` stamps the commit
that carries the fix and the time it was resolved. The commit is a post-commit
step — the squash merge's hash is the one the fix ships in — so run it after
the merge, not at the skill's own commit:

    ~/bin/skill-log resolve --id <invocation> --fix <commit>

`--id` is the invocation id from `show`; `--fix` is the squash merge's hash on
`main`. Re-running is safe — the same row, the same commit. `--dry-run`
previews the update without writing. `stats` then counts the resolved rows in
its `resolved` column, and `show` renders the `fix` and `resolved_at` columns.
A merged copy belongs to the machine that wrote it, so `resolve` refuses one
and names its owner: resolve it there, where the owner's value is the one the
next sync carries.

### Marking a fix

The change that fixes logged friction names the invocations it resolves in a
report file committed with it:

    ~/bin/skill-log fix --id 42 --id 43        # the rows this change fixes
    ~/bin/skill-log fix --thread ses_abc123    # every unresolved row this run logged

That writes `.skill-log/fixes/<branch>.txt`, one `machine#id` per line, and
nothing else. The ids come from the rows: `--id` is a local invocation id from
`show`, and `--thread` selects by provenance — the opencode session, T3 thread,
or parent id the rows were logged under — so selection is not a memory task.
A row owned by another machine is written under that machine's name
(`hersan#7`); the owner resolves it on its next pull, so list the rows from
every machine the change fixes. `fix` validates while the author is still
there: an id this db does not have is refused, an already-resolved row is
skipped, and `--check` validates the file without writing (a malformed line
fails; an unknown marker is a warning, because the row may live on a machine
that has not been synced yet).

Resolution reads the report from the merged tree, so the transport does not
depend on how the forge rebuilds a commit message: `resolve-merged` (the
`post-merge` hook) resolves every report file a pull added or changed, and in a
repo that has `.skill-log/fixes/` it ignores the commit-body trailer (it says
so when it sees one). A repo without that directory keeps the trailer as its
input, so the old flow still works where this repo's report cannot live:

    Skill-log-Fix: omarchy#12, omarchy#14, hermes#7

There the marker is the last paragraph of the PR body — a squash merge makes
the body the commit body — and only the final trailer block is read, so a
marker quoted earlier in prose is not read and a trailer block after it (a
multi-author squash appends `Co-authored-by:`) hides it. `resolve-merged`
reports a marker hidden that way instead of dropping it; if one shows up, run
`resolve --id … --fix <sha>` by hand.

Every marker names its machine, because one id means a different row in each
machine's db and the same merged commit is read on all of them. `show --json`
prints each row's `marker` in exactly that form (`origin_id` for a synced copy,
its own id otherwise). What makes it reliable is that the merge is the trigger:
`scripts/setup-git.sh` installs `post-merge`, so every pull that lands a fix
stamps its rows on its own. It scans only the commits the pull landed, so a
marker is reported once, when it arrives; a rebase-based pull fires no
`post-merge`, so run `resolve-merged` yourself after one. Each machine resolves
the rows it owns — it is the only one that can, and the aggregate reads the
result on its next sync. Re-running is free. Three shapes are reported and left
alone: a marker this db does not have, a marker naming a merged copy (its owner
resolves it), and a row logged after the commit (an id reused by a rebuilt
log).

## Syncing across machines

The log is per-machine, and a row's id is only unique inside the db that wrote
it. One machine can hold every host's rows: run `sync` where the other logs
are reachable — the desktop pulls the VPS, because the VPS cannot reach the
desktop:

    ~/bin/skill-log sync --from hersan

That pulls a consistent read-only snapshot of the remote log over SSH and
merges the rows into the local db. The remote's rows are never modified,
though SQLite does create its `-shm`/`-wal` sidecars beside a WAL db, so the
remote log needs a writable directory; the remote needs `python3`, and its own
`skill-log` version does not matter (an older one merges with blanks for the
columns it predates).

Each merged row keeps its owner: `machine` is its host, and the merge dedupes
on `(machine, origin_id)` — the row's id in the db that wrote it — so
re-running merges nothing twice. The owner is authoritative: `fix` and
`resolved_at` come forward as updates, a snapshot row this db wrote is skipped
(this db owns it), and a copy whose timestamp and skill no longer match its
owner's row is replaced — that pair means the owner's log was rebuilt and
reused its ids. A host renamed between a short name and its FQDN keeps the
spelling the db already holds, so a rename neither lands as a second machine
nor strands the markers written under the old spelling. `show` orders the
aggregate by when a run happened, not by when a sync landed it.

`--remote-db <path>` points at a log outside the remote's own state directory
(which the remote resolves, `XDG_STATE_HOME` included); `--dry-run` runs the
identical merge against a throwaway copy and reports the counts; `--json`
emits them as one object. The merge keys on the name the remote reports for
itself, so an ssh alias never stands in for the machine's identity. The
direction is one-way: the pulling machine is the aggregate, so never sync it
back into another host.

Read the aggregate the same way, with `--machine <host>` to cut to one host:

    ~/bin/skill-log show --machine hersan --last 10
    ~/bin/skill-log stats

## Notes

- This skill's own invocation closes with one row per its Usage log section
  (`add --skill skill-log`) — it logs itself exactly like every other skill.
  A user asking to correct the log's record is the only other reason `add`
  runs here.
- SQLite, not the TSV format show-me-your-work uses for its decision trail:
  problems must group under the invocation that found them and aggregate
  into a per-skill rate, which the role-specific query paths need. The TSV
  log answers to spreadsheets instead.
- `parent` is the dispatched-row column: a subagent's error-rider row
  carries the spawning run's T3 thread id, so a dispatch tree's rows
  coalesce under one thread for dedupe. It is not a row kind — dispatched
  rows still count as invocations (one per error-carrying dispatch,
  bounded); the split is by the column, not a special flag. Double
  logging is legal by construction: an error that surfaces from child to
  parent may appear in both rows, and dedupe is an analysis-time read of
  `parent`, never a reason to skip the write.
- The write is a row insert, not a skill invocation: a run that logs itself
  logs once, reading the log back inserts nothing (an old log file gets
  its schema converged on first touch — one ALTER per missing column, no
  rows), and no part
  of this skill invokes a skill. No recursion exists by construction.

## Usage log

The skill's work ends with exactly one silent write to the local skill log:
run `~/bin/skill-log` once, at the end, with no narration and nothing else
changed on its account:

    ~/bin/skill-log add --skill skill-log

When the run surfaced problems or friction — an ambiguous step, an instruction
that conflicts with reality, a missing tool — pass each finding in its
place:

    ~/bin/skill-log add --skill skill-log \
        --problem "<what struggled or cost the run, one sentence>" \
        --problem "<second finding, one flag per finding>"

A clean run still lands its row, problem-less: the invocation count is the
denominator of the problems/invocation rate. Add `--t3-thread <id>` when the
T3 thread id is in context; the invocation date, project, opencode thread id,
worktree, and machine are auto-detected by the tool. When `~/bin/skill-log`
does not exist, skip the write silently and carry on: the skill's work
outranks its own reporting.
