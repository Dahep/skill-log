# ADR-0002: explicit harness context in the store

**Status:** accepted, 2026-11-11.
**Current rules:** [SPEC.md](../../SPEC.md) §3–§5.

## Context

The store must identify the agent product, session, parent run, model,
repository, worktree and project behind every skill invocation. The review
skill uses those fields to separate instruction defects from environment noise,
so they belong in typed columns rather than a free-form bag.

A product-specific schema would require a schema change and a new release for
every new harness. Generic harness and session fields, plus opt-in adapters
for product-specific context, keep the store stable while allowing additional
agents to contribute the fields they can prove.

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
   | `fix`, `resolved_at` | the resolution fields | unresolved |

   All text columns are `NOT NULL DEFAULT ''`: empty means "unknown or not
   applicable". The SQL layer has no NULL semantics, and each JSON field keeps
   one type.

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
   `parent` or `t3_thread`, and its failure is a blank field, never an error.
   - `opencode` fills `harness=opencode`, `session` from
     `OPENCODE_SESSION_ID`, and `model` from `session_v2` in
     `~/.local/share/opencode/opencode.db`, read-only.
   - `t3` fills `project` from the T3 worktree path when `worktree` is under
     it. `t3_thread` stays caller-supplied because an adapter cannot invent a
     thread id.

6. **Command surface.** The authoring verb is `report`:
   `report --run <id>` selects every row whose `session`, `t3_thread` or
   `parent` matches, `report --id` and `report --skill` select explicitly, and
   `report --check` validates an existing file without writing. The artifact
   lives at `.skill-log/reports/<slug>.md`, one marker per line; a repo without
   that directory keeps trailer mode. `stats --by-model` is an alias for
   `stats --by model`, with `skill` the default and `harness`, `model`, `repo`,
   `worktree`, `machine` or `project` as keys. `show` supports `--harness`,
   `--repo` and `--run`. `skills template` has `show`, `seed` and `reset`
   subcommands. `show --json` exposes the context fields flat.

7. **The CLI is built for agents.** Every verb's `--help`, at every nesting
   level, ends with 2–4 real invocations, and usage errors reuse the same
   examples. `add --problem -` reads the text from stdin and refuses when
   stdin is a terminal, so a hook can never block. `--dry-run` exists on every
   mutating verb; `--force` is the only confirmation and no verb prompts.
   Success output carries the handle the next verb needs: a marker from `add`,
   marker plus commit from `resolve`, a path from `report`. `add` is
   deliberately not idempotent: the log records occurrences, so a retry must
   remain distinguishable from a genuine repeat.

8. **The store is created, not inherited.** Version 1.0 defines its own
   schema and creates it on the first write. An existing file that is not this
   schema is refused by name ("not a skill-log store" or "an older skill-log
   store"), with no half-migration. `PRAGMA user_version = 1` stamps the
   schema; a store stamped newer than the binary is refused by name.

   The refusal kind is a value carried by the store layer, never a word
   re-derived from an error message. The message names the path the caller
   gave, and a path can contain any word in the vocabulary, so text matching
   would let the path choose the answer.

9. **One store per machine.** Multi-machine consolidation — `sync`, an
   aggregate store, merged copies, owner authority — is out of scope. Rows
   still carry `machine`, because the marker grammar (`machine#id`) and the
   report contract need the origin.

10. **The resolution rules remain explicit.** Newest-marker-wins,
    skip-a-row-logged-after-the-commit, idempotent resolution, artifact versus
    trailer mode, hidden-marker reporting, one-line failures and exit codes
    are defined in [SPEC.md](../../SPEC.md).

## Why this shape

- **The review skill gets what it needs to classify friction.** Harness,
  session, model, repo and worktree are the slicing keys that separate an
  instruction defect from environment noise; a free-form bag would make each
  of those a string parse.
- **A new harness is a new adapter, not a store redesign.** `harness` and
  `session` are the generic pair; a product-specific field becomes a column
  only when it is genuinely queried.
- **Model detection stops being a release dependency.** Reading opencode's
  database is one adapter among several, off unless asked for, so an upstream
  schema change degrades to a blank `model`.
- **Scope stays honest.** A single-writer store needs no origin ids, copy
  rules or SSH transport.

## Consequences

- One store serves opencode today and any harness later, with no legacy
  columns or origin index.
- The review skill can cut friction by harness, session, model, repo and
  worktree without parsing.
- `show --json` exposes the context fields as one stable shape.
- The report artifact uses `.skill-log/reports/` and the trailer fallback.
- Switching a machine over can require an external data move because the tool
  refuses a store with another schema instead of converting it.
- Adapters add a seam with multiple implementations; the seam is worth it
  because harness knowledge stays out of every future release.
- `sync` and the machinery it requires are outside version 1.0; introducing
  them is a new design.

## Enforced by

- An adapter never runs unasked: with `opencode.db` present and no
  `SKILL_LOG_ADAPTERS`, `add` records `session` from the environment only and
  no `model`.
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
- `repo` and `worktree` are empty outside a git checkout and correct inside a
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
- **Keeping product-specific columns and nothing else**: ties the tool to a
  fixed set of agent products and `model` to opencode's private schema.
- **`repo` as `owner/name`**: needs credential-stripping URL parsing for a
  grouping gain the basename does not miss.
- **Converting an existing store during setup**: moving existing rows is a
  machine-setup task, and a conversion path would outlive its usefulness.
- **Shipping `sync` in version 1.0**: it would dictate origin ids, copy rules
  and an SSH transport the product does not need.
