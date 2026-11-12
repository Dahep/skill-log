# ADR-0002: explicit harness context in the store

**Status:** proposed, 2026-11-11.
**Amends:** the data model in
[issue #1](https://github.com/Dahep/skill-log/issues/1), the storage section in
[issue #3](https://github.com/Dahep/skill-log/issues/3), ADR-0001's "no store
migration" consequence, and 1.0's scope: multi-machine consolidation is out.
**Reference implementation:** dotfiles branch `t3/e53b1745` (2,323 lines, the
only copy carrying `fix` and report files). It is the port source and the
parity target, not a store to inherit.

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
| Skills | the usage-log block teaches `--t3-thread` |

The reference store shows what that costs in practice: 102 rows, all carrying
`opencode_thread`, 12 carrying `t3_thread`, 16 carrying `parent`. A Claude Code
or Codex user gets blanks in every one of those fields, and a new harness needs
a schema change plus a binary release.

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
   | `fix`, `resolved_at` | the resolution contract from #1, unchanged | never |

   All text columns are `NOT NULL DEFAULT ''`: empty means "unknown or not
   applicable". The SQL layer stays free of NULL semantics, and #1's JSON
   shapes keep one type per field.

2. **`problems.problem` is the agent's description.** One `--problem` per
   finding, each carrying the agent's own sentence about what went wrong.
   There is no separate run-narrative column: it would duplicate the same
   signal and split the rate's numerator across two tables. A run with two
   distinct frictions has two problems; a clean run has none.

3. **`parent` is a free-form string**, not a foreign key. It names the
   spawning run in the same namespace as `session`, so it survives being read
   by anything that did not write the row and still expresses a parent that is
   not in this store. Dispatch-tree coalescing is `parent = <run id>` or
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
     `$T3CODE_HOME/worktrees/<project>/…` when `worktree` is under it, and
     from `$HOME/.t3/worktrees/<project>/…` when `T3CODE_HOME` is unset —
     T3's own default home is `~/.t3`.
     `t3_thread` stays caller-supplied: the adapter cannot invent a thread id,
     and the dispatching skill already knows it.
   - This machine's wrapper exports `SKILL_LOG_ADAPTERS=opencode`, so every
     row here records the harness and a real session id without every skill
     passing flags.

6. **Command surface.** The authoring verb is `report` (formerly `fix`):
   `report --run <id>` selects every row whose `session`, `t3_thread` or
   `parent` matches, `report --id` and `report --skill` select explicitly, and
   `report --check` validates an existing file without writing. The artifact
   lives at `.skill-log/reports/<slug>.md` (formerly `fixes/`), one marker per
   line; a repo without that directory keeps trailer mode. `stats --by-model`
   becomes `stats --by <column>` (same alias), with `skill` the default and
   `harness`, `model`, `repo`, `worktree`, `machine` or `project` as keys.
   `show` gains `--harness`, `--repo` and `--run`. `skills template` gains real
   subcommands — `show`, `seed` (with `--force`), `reset` — instead of three
   exclusive mode flags. `show --json` exposes the new fields flat and drops
   `opencode_thread`; `t3_thread` and `project` stay.

7. **The CLI is built for agents.** Every verb's `--help`, at every nesting
   level, ends with 2–4 real invocations, and usage errors reuse the same
   examples. `add --problem -` reads the text from stdin and refuses when
   stdin is a terminal, so a hook can never block. `--dry-run` exists on every
   mutating verb; `--force` is the only confirmation and no verb prompts;
   `skills template reset` refuses while user copies exist without `--force`.
   Success output carries the handle the next verb needs — a marker from
   `add`, marker plus commit from `resolve`, a path from `report`. `add` is
   deliberately not idempotent: the log records occurrences, a retry is
   indistinguishable from a genuine repeat, and deduping would hide the second
   occurrence of one error. `add --help`, the bundled skills and the usage-log
   template all say so.

8. **The store is created, not inherited.** 1.0 defines its own schema and
   creates it on the first write. It does not convert the Python-era store:
   moving that data is part of switching a machine's setup, not part of this
   project. An existing file that is not this schema is refused by name
   ("not a skill-log store" or "an older skill-log store"), with no
   half-migration. `PRAGMA user_version = 1` stamps the schema; a store
   stamped newer than the binary is refused by name.

   The refusal kind is a value carried by the store layer, never a word
   re-derived from an error message. The message names the path the caller
   gave, and a path can contain any word in the vocabulary (`/tmp/older/x.db`,
   `newer5.db`), so text matching would let the path choose the answer — and
   `newer5` would even supply the version number the refusal reports.

9. **One store per machine.** Multi-machine consolidation — `sync`, an
   aggregate store, merged copies, owner authority — is out of scope for this
   project at this time; the user's own setup handles it internally. Rows
   still carry `machine`, because the marker grammar (`machine#id`) and the
   report contract are unchanged, and because an external consolidator needs
   the origin of a row.

10. **The store rules that remain do not move.** Newest-marker-wins,
   skip-a-row-logged-after-the-commit, idempotent resolution, artifact vs
   trailer mode, hidden-marker reporting, one-line failures and exit codes are
   unchanged.

## Why this shape

- **The review skill gets what it needs to classify friction.** Harness,
  session, model, repo and worktree are the slicing keys that separate an
  instruction defect from environment noise; a free-form bag would make each
  of those a string parse.
- **A new harness is a new adapter, not a store redesign.** `harness` and
  `session` are the generic pair; a product-specific field becomes a column
  only when it is genuinely queried (`project`, `t3_thread`), which is why the
  T3 pair is allowed to sit empty.
- **Model detection stops being a release dependency.** Reading opencode's
  database becomes one adapter among several, off unless asked for, so an
  upstream schema change degrades to a blank `model`.
- **Scope stays honest.** A single-writer store needs no origin ids, no copy
  rules and no SSH transport; leaving them out removes the merge surface from
  1.0 entirely.

## Consequences

**Positive**

- One store serves opencode today and any harness later, with no compatibility
  code in the port: no backfill, no legacy columns, no origin index.
- The review skill can cut friction by harness, session, model, repo and
  worktree without parsing.
- The dotfiles skill suite is re-rendered from one neutral template; the
  subagent error rider keeps `--parent`, which was already neutral in name.

**Negative**

- `show --json` drops `opencode_thread` and adds five fields, so 1.0 is a
  shape break for any consumer of the old thread field.
- The authoring verb is renamed `fix` → `report` and the artifact directory
  `fixes/` → `reports/`, so the review template, the loop docs and the
  reference harness all change, and the parity gate has to run the new CLI
  against the renamed cases.
- Switching this machine over needs an external data move: the new binary will
  refuse the Python-era file rather than convert it.
- Adapters add a seam with two implementations; the seam is only worth it
  because the alternative is compiling harness knowledge into every future
  release.
- `sync` and everything that existed to serve it (origin ids, copy rules,
  owner handling) leave 1.0; reintroducing them is a new design.

## Enforced by

- An adapter never runs unasked: with `opencode.db` present and no
  `SKILL_LOG_ADAPTERS`, `add` records `session` from the env only and no
  `model`.
- Explicit context beats an adapter: `--model` wins over the opencode lookup.
- `report --run` selects a row and the rows it dispatched; `report --check`
  validates without writing, and `.skill-log/reports/` is the only directory
  `setup` creates for it.
- `stats --by repo` and `stats --by harness` group correctly on a store with
  mixed values, and a value nobody has recorded yields no rows rather than an
  error.
- An older or foreign store is refused with one named line and nothing written.
- Two identical `add` calls produce two rows, and `add --help` says a retry
  duplicates.
- `add --problem -` on a terminal exits 2 instead of waiting for input.
- `repo`/`worktree` are empty outside a git checkout and correct inside a
  linked worktree.

## Alternatives rejected

- **A key/value `context` table** for every non-core field: every read joins,
  the JSON shape gains a nested object, and the review skill's common cuts
  become string lookups.
- **A single `error` narrative column**: duplicates `problems.problem`, and
  the rate's numerator loses its per-finding count.
- **`parent_id` as a foreign key**: trivial local tree walks, but it only
  names rows this store wrote; a parent in another harness session or another
  store cannot be expressed.
- **Keep the T3/opencode columns and nothing else** (what #1 and #3 say
  today): ships a tool named for skills that only understands two agent
  products, and ties `model` to opencode's private schema.
- **`repo` as `owner/name`**: needs credential-stripping URL parsing for a
  grouping gain the basename does not miss; the worktree path already
  disambiguates two same-named checkouts on one machine.
- **Migrating the Python-era store in 1.0**: the 102 rows belong to one
  machine's setup switch, and a conversion path would outlive its usefulness.
- **Shipping `sync` in 1.0**: it is the largest surface in the reference
  implementation and the part the user's own setup covers; keeping it would
  dictate origin ids, copy rules and an SSH transport the product does not
  need yet.
