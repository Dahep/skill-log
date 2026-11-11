# ADR-0002: explicit harness context in the store

**Status:** proposed, 2026-11-11.
**Amends:** the data model in
[issue #1](https://github.com/Dahep/skill-log/issues/1), the storage section in
[issue #3](https://github.com/Dahep/skill-log/issues/3), and ADR-0001's
"no store migration" consequence. It was written before any code was ported.
**Reference implementation:** dotfiles branch `t3/e53b1745` (2,323 lines, the
only copy carrying `fix` and report files). It is the port source and the
parity target.

## Context

The contract in #1 is sound, but its vocabulary describes one agent setup. The
reference implementation assumes T3 Code and opencode in six places:

| Surface | Assumption |
|---|---|
| Schema | fixed `parent`, `t3_thread`, `opencode_thread` columns |
| `add` flags | `--t3-thread`, `--opencode-thread`, `--parent` |
| Autodetect | `OPENCODE_SESSION_ID`; `$T3CODE_HOME/worktrees/<project>`; reads `~/.local/share/opencode/opencode.db` (`session_v2.model`, a JSON value) to fill `model` |
| `fix` selection | `--thread` matches `opencode_thread` OR `t3_thread` OR `parent` |
| `show --json` | exports both thread ids as stable shape |
| Sync and skills | `SYNC_COLUMNS` carries both; the usage-log block teaches `--t3-thread` |

The live store shows what that costs in practice: 102 rows, all carrying
`opencode_thread`, 12 carrying `t3_thread`, 16 carrying `parent`. A Claude
Code or Codex user gets blanks in every one of those fields, and a new harness
needs a schema change plus a binary release.

The specification already says the user owns *what gets logged* (the usage-log
template) while the schema fixes *which fields exist*. That asymmetry is the
defect. Two smaller ones ride along: `project` has three definitions in the
reference (T3 worktree segment, git remote basename, directory name), and
`model` detection depends on another tool's private schema, so a routine
opencode upgrade can silently empty the rotation view.

The consumer that needs these fields is the review skill: it clusters logged
friction, and to separate an instruction defect from environment noise it
needs to know which harness, session, model, repo and worktree a run came
from. That is why they belong in typed columns rather than a free-form bag.

## Decision

1. **One row, explicit harness context.** `invocations` carries:

   | Column | Meaning | Empty when |
   |---|---|---|
   | `ts` | ISO 8601 with the writer's offset | never |
   | `skill` | the invoked skill's name | never |
   | `harness` | the agent product that ran the skill: `opencode` today, later `t3`, `claude`, … | unknown |
   | `session` | that harness's session id, opaque to the tool | unknown |
   | `parent` | the spawning run's id, in the same namespace as `session` | the run was not dispatched |
   | `model` | `provider/id` by convention; never parsed | unknown |
   | `repo` | the git repository the run happened in: origin remote's basename, else the toplevel directory's name | not in a repo |
   | `worktree` | the working-tree root (`git rev-parse --show-toplevel`) | not in a repo |
   | `project` | the T3 project grouping | the `t3` adapter is off, or the run is outside T3 |
   | `t3_thread` | the T3 thread id | the caller did not pass one |
   | `machine` | the hostname | never |
   | `fix`, `resolved_at`, `origin_id` | the resolution and merge contract from #1, unchanged | never |

   All text columns are `NOT NULL DEFAULT ''`, as today: empty means "unknown
   or not applicable". The SQL layer stays free of NULL semantics, and #1's
   JSON shapes keep one type per field.

2. **`problems.problem` is the agent's description.** One `--problem` per
   finding, each carrying the agent's own sentence about what went wrong.
   There is no separate run-narrative column: it would duplicate the same
   signal and split the rate's numerator across two tables. A run with two
   distinct frictions has two problems; a clean run has none.

3. **`parent` stays a free-form string**, not a foreign key. It is the
   spawning run's id in the same namespace as `session`, so it survives sync
   with no id remapping and still expresses a parent that lives on another
   machine. Dispatch-tree coalescing is `parent = <run id>` or
   `session = <run id>`, whichever names the run.

4. **The caller supplies context; adapters fill what they can prove.** Flags:
   `add --harness`, `--session`, `--parent`, `--model`, `--repo`,
   `--worktree`, `--project`, `--t3-thread`, `--machine`. Environment
   fallbacks use one prefix: `SKILL_LOG_HARNESS`, `SKILL_LOG_SESSION`,
   `SKILL_LOG_PARENT`, `SKILL_LOG_MODEL`, `SKILL_LOG_REPO`,
   `SKILL_LOG_WORKTREE`, `SKILL_LOG_PROJECT`, `SKILL_LOG_T3_THREAD`.

5. **Adapters are opt-in and never default.** `SKILL_LOG_ADAPTERS=opencode` or
   `--adapter opencode` enables one. Precedence is explicit flag, then its
   `SKILL_LOG_*` variable, then an enabled adapter, then built-in detection
   (git for `repo`/`worktree`, hostname for `machine`). An adapter may not set
   `parent`, and its failure is a blank field, never an error.
   - `opencode` (the 1.0 target) fills `harness=opencode`, `session` from
     `OPENCODE_SESSION_ID`, and `model` from `session_v2` in
     `~/.local/share/opencode/opencode.db`, read-only.
   - `t3` (optional) fills `project` from
     `$T3CODE_HOME/worktrees/<project>/…` when `worktree` is under it.
     `t3_thread` stays caller-supplied: the adapter cannot invent a thread id,
     and the dispatching skill already knows it.
   - This machine's wrapper exports `SKILL_LOG_ADAPTERS=opencode`, so every
     row here records the harness and a real session id without every skill
     passing flags.

6. **Command surface deltas.** `fix --thread` becomes `fix --run` (the old
   flag stays as an alias in 1.0), and it selects rows where `session`,
   `t3_thread` or `parent` matches. `stats --by-model` becomes `stats --by
   <column>` (same alias), where the column is `skill` (default), `harness`,
   `model`, `repo`, `worktree`, `machine`, `session` or `project`. `show`
   gains `--harness` and `--repo`. `show --json` exposes the new fields flat
   and drops `opencode_thread`; `t3_thread` and `project` stay.

7. **The store migrates additively on first write.** Schema v2 adds `harness`,
   `session` and `repo`, and stamps `PRAGMA user_version = 2`. The first write
   backfills in one transaction: `session = opencode_thread`,
   `harness = 'opencode'` where a session or a T3 thread exists, `parent`,
   `project`, `t3_thread`, `worktree` and `model` keep their values, and `repo`
   stays empty because an old worktree path does not prove a repository. The
   legacy `opencode_thread` column is kept for the transition and dropped in
   2.0. Reads may converge a missing column as #1 already allows, but they
   never backfill rows and never stamp a version; a row with an empty `session`
   falls back to `opencode_thread`, so an unmigrated file renders correctly. A
   store stamped newer than the binary is refused by name.

8. **The store rules do not move.** Owner authority, `(machine, origin_id)`
   dedupe, newest-marker-wins, skip-after-the-commit, idempotent resolution,
   one-line failures and exit codes are unchanged. New columns ride along in
   sync like the existing ones.

## Why this shape

- **The review skill gets what it needs to classify friction.** Harness,
  session, model, repo and worktree are the slicing keys that separate an
  instruction defect from environment noise; a free-form bag would make each
  of those a string parse.
- **A new harness is a new adapter, not a store redesign.** `harness` and
  `session` are the generic pair; a product-specific field becomes a column
  only when it is genuinely queried (`project`, `t3_thread`), which is why the
  T3 pair is allowed to sit empty.
- **Nothing in the existing store is lost.** The columns map almost 1:1 onto
  the 102 rows (`opencode_thread`→`session`, both thread ids preserved), so
  the migration is a rename plus two columns, not a repack.
- **Model detection stops being a release dependency.** Reading opencode's
  database becomes one adapter among several, off unless asked for, so an
  upstream schema change degrades to a blank `model`.

## Consequences

**Positive**

- One store serves opencode today and any harness later, with no loss of the
  existing rows.
- The review skill can cut friction by harness, session, model, repo and
  worktree without parsing.
- The dotfiles skill suite is re-rendered from one neutral template; the
  subagent error rider keeps `--parent`, which was already neutral in name.

**Negative**

- `show --json` drops `opencode_thread` and adds five fields, so 1.0 is a
  shape break for any consumer of the old thread field.
- The schema-version stamp, the backfill and the read fallback are new code in
  a rewrite that was scoped to porting statements "close to verbatim".
- Adapters add a seam with two implementations; the seam is only worth it
  because the alternative is compiling harness knowledge into every future
  release.
- `repo` is empty for every pre-migration row: the old `worktree` path cannot
  prove a repository existed.

## Enforced by

- An adapter never runs unasked: with `opencode.db` present and no
  `SKILL_LOG_ADAPTERS`, `add` records `session` from the env only and no
  `model`.
- Explicit context beats an adapter: `--model` wins over the opencode lookup.
- `fix --run` selects a row and the rows it dispatched; `--thread` behaves
  identically in 1.0.
- `stats --by repo` and `stats --by harness` group correctly on a mixed store,
  and a value nobody has recorded yields no rows rather than an error.
- A v1 fixture migrates on the first write, renders before it, and a v3 stamp
  is refused with one named line.
- `repo`/`worktree` are empty outside a git checkout and correct inside a
  linked worktree.

## Alternatives rejected

- **A key/value `context` table** for every non-core field: every read joins,
  the JSON shape gains a nested object, and the review skill's common cuts
  become string lookups.
- **A single `error` narrative column**: duplicates `problems.problem`, and
  the rate's numerator loses its per-finding count.
- **`parent_id` as a foreign key**: trivial local tree walks, but sync has to
  remap ids and a parent on another machine cannot be expressed.
- **Keep the T3/opencode columns and nothing else** (what #1 and #3 say
  today): ships a tool named for skills that only understands two agent
  products, and ties `model` to opencode's private schema.
- **`repo` as `owner/name`**: needs credential-stripping URL parsing for a
  grouping gain the basename does not miss; the worktree path already
  disambiguates two same-named checkouts on one machine.
