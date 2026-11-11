# ADR-0002: harness-neutral context in the store

**Status:** proposed, 2026-11-11.
**Amends:** the data model in
[issue #1](https://github.com/Dahep/skill-log/issues/1) and the storage
section in [issue #3](https://github.com/Dahep/skill-log/issues/3). Both were
written against one agent setup; this record generalizes them before any code
is ported.
**Reference implementation:** dotfiles branch `t3/e53b1745` (2,323 lines, the
only copy carrying `fix` and report files). It is the port source and the
parity target.

## Context

The contract in #1 is sound, but its vocabulary describes one environment.
The reference implementation assumes T3 Code and opencode in six places:

| Surface | Assumption |
|---|---|
| Schema | fixed `parent`, `t3_thread`, `opencode_thread` columns |
| `add` flags | `--t3-thread`, `--opencode-thread`, `--parent` |
| Autodetect | `OPENCODE_SESSION_ID`; `$T3CODE_HOME/worktrees/<project>`; reads `~/.local/share/opencode/opencode.db` (`session_v2.model`, a JSON value) to fill `model` |
| `fix` selection | `--thread` matches `opencode_thread` OR `t3_thread` OR `parent` |
| `show --json` | exports both thread ids as stable shape |
| Sync and skills | `SYNC_COLUMNS` carries both; the usage-log block teaches `--t3-thread` |

The live store shows what that costs in practice: 102 rows, all carrying
`opencode_thread`, only 12 carrying `t3_thread`, 16 carrying `parent`. A
Claude Code or Codex user gets blanks in every one of those fields, and a new
harness needs a schema change plus a binary release.

The specification already says the user owns *what gets logged* (the usage-log
template) while the schema fixes *which fields exist*. That asymmetry is the
defect. Two smaller ones ride along: `project` has three definitions in the
reference (T3 worktree segment, git remote basename, directory name), and
`model` detection depends on another tool's private schema, so a routine
opencode upgrade can silently empty the rotation view.

## Decision

1. **Neutral context columns.** `invocations` carries `id, ts, skill, parent,
   run, model, project, worktree, machine, fix, resolved_at, origin_id`.
   - `run` — the caller's run/session id, free-form, opaque to the tool. It is
     the grouping token for provenance selection.
   - `parent` — the `run` value of the run that spawned this one. `fix --run X`
     matches `run = X OR parent = X`, so a dispatch tree still coalesces; the
     column name stays, only its documented meaning changes.
   - `model` — free-form, `provider/id` by convention. The tool never parses
     it.
   - `project` — one definition: the origin remote's basename, falling back to
     the worktree directory name. `--project` overrides.
   - `worktree` — the git toplevel of the working directory, else the working
     directory. `--worktree` overrides.
   - `machine` — the hostname. `--machine` overrides.
2. **An extras table for everything else.**
   `context(invocation_id, key, value)`, primary key `(invocation_id, key)`,
   cascading delete, indexed on `key`. Harness ids live here
   (`t3.thread`, `opencode.session`, `claude.session`), as does any future
   per-run fact. No JSON column, no parser.
3. **The caller supplies context by default.** `add --run`, `--parent`,
   `--model`, `--project`, `--worktree`, `--machine`, and a repeatable
   `--context key=value`. Environment fallbacks use one prefix:
   `SKILL_LOG_RUN`, `SKILL_LOG_PARENT`, `SKILL_LOG_MODEL`,
   `SKILL_LOG_PROJECT`, `SKILL_LOG_WORKTREE`, `SKILL_LOG_CONTEXT`
   (comma-separated `key=value`). The core binary reads no harness-specific
   variable.
4. **Adapters are opt-in, never default.** `SKILL_LOG_ADAPTERS=opencode,t3`
   (or `--adapter`) enables them. Precedence for every context field is:
   explicit flag, then its `SKILL_LOG_*` variable, then an enabled adapter,
   then the built-in detection (git for `project`/`worktree`, hostname for
   `machine`). An adapter may not set `run` or `parent`, and an adapter
   failure is a blank field, never an error. 1.0 ships two: `opencode` (fills
   `model` from `session_v2` and records `opencode.session`) and `t3` (fills
   `project` from `$T3CODE_HOME/worktrees/<segment>` and records `t3.thread`).
   A wrapper that knows the harness sets `SKILL_LOG_RUN` if it wants run-level
   grouping.
5. **Command surface deltas.** `fix --thread` becomes `fix --run` (the old
   flag stays as an alias in 1.0). `stats --by-model` becomes `stats --by
   <key>` (same alias), where a key is a column (`skill`, `model`, `project`,
   `worktree`, `machine`, `run`, `parent`) or a context key. `show` gains
   `--context key=value`. `show --json` exposes `run`, `parent`, and a nested
   `context` object; `t3_thread` and `opencode_thread` leave the shape.
   `stats --by <column> --json` keeps the column as a flat field, matching
   `--by-model` today; `stats --by <context key> --json` carries it as a
   nested `context` object, matching `show`.
6. **Migration is additive and happens on write.** Schema v2 adds the `run`
   column and the `context` table, and stamps `PRAGMA user_version = 2`. The
   first write backfills, in one transaction: `run` = `t3_thread`, else
   `opencode_thread`; `context` rows `t3.thread` and `opencode.session` for
   non-empty values. The old columns stay readable for the transition and drop
   in 2.0. Reads may converge a missing column as #1 already allows, but they
   never backfill rows and never stamp a version; an unversioned file reads
   normally, with an empty `run` falling back to the old columns. A store
   stamped newer than the binary is refused by name.
7. **The store rules do not move.** Owner authority, `(machine, origin_id)`
   dedupe, newest-marker-wins, idempotent resolution, one-line failures and
   exit codes are unchanged. `context` rows ride along in sync like problem
   rows.

## Why this shape

- **The template and the schema now own the same thing.** If the usage-log
  block decides which facts a run reports, the store must not refuse the ones
  it does not recognize. Extras make the template genuinely authoritative.
- **A new harness is data, not a release.** Claude Code today, something else
  next year: a new key and a template line, no schema version, no rebuild.
- **Typed cuts stay cheap.** `model`, `project`, `worktree`, `run` and
  `machine` are the cuts that matter for reading friction and for the rotation
  view; keeping them as columns avoids a join on every `show` and `stats`.
- **Model detection stops being a release dependency.** Reading opencode's
  database becomes one adapter among several, off unless asked for, so an
  upstream schema change degrades to a blank `model` instead of a broken
  column.

## Consequences

**Positive**

- One store serves every harness, with no loss of the existing 102 rows: both
  thread ids survive in `context`.
- `stats --by <key>` generalizes the rotation view to any tracked fact.
- The dotfiles skill suite is re-rendered from one neutral template; the
  subagent error rider keeps `--parent`, which was already neutral in name.

**Negative**

- `show --json` gains a nested object and loses two flat fields, so 1.0 is a
  shape break for any consumer of `t3_thread`/`opencode_thread`.
- `stats --by` over an extras key needs a join path that `--by-model` never
  needed.
- The schema-version stamp, the backfill and the read fallback are new code in
  a rewrite that was scoped to porting statements "close to verbatim".
- Adapters add a seam with two implementations and one rule each; the seam is
  only worth it because the alternative is compiling harness knowledge into
  every future release.

## Enforced by

- An adapter never runs unasked: with `opencode.db` present and no
  `SKILL_LOG_ADAPTERS`, `add` records no model.
- Explicit context beats an adapter: `--model` wins over the opencode lookup.
- Unknown keys round-trip: `add --context harness=claude` reappears in `show
  --json` and is filterable with `show --context harness=claude`.
- `fix --run` selects both the row and its dispatched children; `--thread`
  behaves identically in 1.0.
- `stats --by model` and `stats --by <extras key>` both produce the rate
  columns, and a key nobody has recorded yields no rows rather than an error.
- A v1 fixture migrates on the first write, keeps rendering before it, and a
  v3 stamp is refused with one named line.

## Alternatives rejected

- **Rename only** (`run`, `parent`), fixed field set: loses the T3
  thread/opencode session distinction on the 12 rows carrying both, and a
  third harness still needs a schema change.
- **Everything in `context`**, no context columns: every read joins, the JSON
  shape moves furthest from #1, and it buys no capability over this design.
- **Keep the harness columns** (what #1 and #3 say today): ships a tool named
  for skills that only understands two agent products, and ties `model` to
  opencode's private schema.
- **Extras as one JSON column**: needs a JSON parser in a binary that
  deliberately has none.
