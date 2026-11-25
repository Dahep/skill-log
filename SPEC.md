# skill-log — specification

**Status:** normative, 1.0. This file is the single source of truth for what
skill-log does. How the documents divide, and how each changes, is defined in
`AGENTS.md` §Specification.

| Document | Answers |
|---|---|
| `SPEC.md` (this file) | What the tool does: commands, flags, exit codes, store, markers, reports, resolution, skills, setup, distribution, testing |
| `docs/adr/` | Why each shape was chosen, and what was rejected |
| `CONTEXT.md` | Vocabulary: what the terms mean |
| Issues | Work items: acceptance criteria and blockers |

**Contents**

1. [Purpose](#1-purpose)
2. [Scope and invariants](#2-scope-and-invariants)
3. [Data model and store](#3-data-model-and-store)
4. [Context fields and adapters](#4-context-fields-and-adapters)
5. [Commands](#5-commands)
6. [Markers and reports](#6-markers-and-reports)
7. [Skills and templates](#7-skills-and-templates)
8. [Distribution and build](#8-distribution-and-build)
9. [Testing](#9-testing)
10. [Deferred and out of scope](#10-deferred-and-out-of-scope)

---

## 1. Purpose

Record every agent-skill invocation, the friction it produced and the tool
calls that failed, keep the record local, and close friction by naming the
change that fixed it.

The product is one loop, and every command is a step in it:

1. **Adopt** — a repo's skills are swept so each one ends its run with a row.
   `skills audit` reports, `skills adopt` writes. `setup` installs the two
   bundled skills where the agent reads skills.
2. **Record** — every skill run ends with one `add`: when, which skill,
   harness, session, parent, model, repo, worktree, project, machine, how the
   skill was in play, and zero or more problems. A clean run still writes; the
   invocation count is the denominator.
3. **Observe** — `harvest` reads the harness's own store and derives what no
   agent has to remember: every skill call, every read of a skill file, and
   every failed tool call, clustered into signatures and attributed to the
   invocation it followed. An error needs no invocation to be recorded; the
   ones that have none are the documentation worklist.
4. **Review** — the bundled `skill-friction-review` skill reads the
   invocations, the problems and the error signatures, groups them by skill and
   theme, separates instruction defects from environment noise, and decides
   what to fix. This is the only step that needs judgment, and nothing
   automates it.
5. **Name** — the change that addresses those problems runs
   `report --run <id>` (or `--id`, `--skill`, `--error`, `--signature`). That
   writes `.skill-log/reports/<slug>.md` listing the markers it addresses —
   machine names and local ids only — and the file is committed with the
   change. In a repo without a report directory, the same markers ride a commit
   trailer.
6. **Close** — `setup` installed a post-merge hook. When the fix lands, the
   hook runs `resolve-merged`, which stamps each named row — or every row a
   named signature covers — with the commit that carried the report and the
   time.

## 2. Scope and invariants

- One CLI, one store per machine, no daemon, no network.
- The CLI is the public surface. The store schema and the report format are
  contracts, not APIs.
- A marker is `machine#row`: a bare id is an invocation, `e<id>` an error row,
  `s<id>` a signature. The machine is required because ids are per store.
- A marker naming another machine is **foreign**: reported, never stamped.
  There is no owner lookup and no cross-machine resolution in 1.0. The rows a
  store holds do not change that: only this host's own spelling stamps. The one
  exception is a stored row with an empty `machine` column — written before
  `add` always filled it — and that row belongs to the machine reading it.
- Reports carry machine names and local ids only — never problem text, error
  text or project details.
- Newest marker wins. A row whose timestamp is after the named commit is
  skipped. Resolution is idempotent.
- Reads never create the state directory, an empty database, or a missing
  store.
- The store is created, never inherited or converted. A damaged, foreign or
  older file is refused by name.
- Nothing outside the local store writes its rows.
- The harness store is an input and is read-only. The tool never writes it; a
  missing, unreadable or changed harness store is a blank or a named skip,
  never a failure unless `--strict` is given.
- Error rows are derived. Only `harvest` creates them; `add` never does, though
  it may re-attribute an unresolved one (§3 Attribution).
- Attribution is local and evidence-based: the same session, or an ancestor
  the harness records, at or before the error. Never a time window alone, and
  never across repositories.
- An evidence grade only rises. `harvest` may upgrade a row that is below the
  grade it can prove; nothing downgrades one.
- A signature is allocated once per store and never re-pointed, so a marker
  naming it keeps its meaning.
- The fence is the only provenance for generated skill text. Text outside a
  fence is user-owned and is never read, matched, rewritten or deleted.
- The post-merge hook never changes a pull's exit status.
- Exit codes: `0` success or nothing to do, `1` operational failure, `2` usage.
  Each failure carries exactly one diagnostic line; a validating verb may add its
  findings as `skill-log: `-prefixed lines. No tracebacks. JSON goes to stdout
  only.

`CONTEXT.md` defines the terms these rules use. Read it before adding a
command, a column or a report field.

## 3. Data model and store

### Schema

Four tables, `PRAGMA user_version = 1`, `PRAGMA journal_mode = WAL`,
`PRAGMA foreign_keys = ON`, a busy timeout on connect, and a bounded
whole-attempt retry budget for writes.

1.0 is unreleased, so the error and signature tables belong to the first
schema rather than to a migration. A store stamped with any other version is
still refused by name.

`invocations`:

| Column | Meaning | Empty when |
|---|---|---|
| `id` | local row id, allocated by the store | never |
| `ts` | ISO 8601 with the writer's offset | never |
| `skill` | the invoked skill's name | never |
| `evidence` | how the skill was in play — see `Evidence grades` below | never |
| `evidence_ref` | the harness call id this row claims: proven for `call` and `read`, a claim otherwise | no claimed call |
| `harness` | the agent product that ran the skill (`opencode` today, later others) | unknown |
| `session` | that harness's session id, opaque to the tool | unknown |
| `parent` | the spawning run's id, in the same namespace as `session` | not dispatched |
| `model` | `provider/id` by convention; never parsed | unknown |
| `repo` | the origin remote's basename, else the toplevel directory's name | not in a repo |
| `worktree` | `git rev-parse --show-toplevel` | not in a repo |
| `project` | the T3 project grouping | the `t3` adapter is off, or outside T3 |
| `t3_thread` | the T3 thread id | the caller did not pass one |
| `machine` | the hostname | never |
| `fix` | the commit that resolved the row | unresolved |
| `resolved_at` | when it was stamped | unresolved |

All text columns are `NOT NULL DEFAULT ''`. Empty means "unknown or not
applicable", so the SQL layer has no NULL semantics and every JSON field keeps
one type — except the preview's `id`, which is null.

`problems` is keyed `(invocation_id, ordinal)`, carries one sentence of
friction per row, and cascades with its invocation. Problems are separate rows
so invocation count stays the denominator of the problems-per-invocation rate.
A run with two distinct frictions has two problems; a clean run has none.

Timestamps keep the writer's offset for display and ordering by their
normalized instant for comparison. `resolve-merged` compares a row's instant
against the named commit's time; comparing the offset strings instead would
mis-stamp across offsets.

### Evidence grades

A row exists because a skill was in play, and the grade says what proves it.
The ladder is ordered `call` > `read` > `body` > `listed` > `attested`, and no
row claims a grade above its proof.

| Grade | What proves it | Written by |
|---|---|---|
| `call` | a `skill` tool call, with its call id | `harvest` |
| `read` | a read, grep, glob or shell call naming a skill directory, with its call id | `harvest` |
| `body` | the skill's body text is in the run's context | `add` only |
| `listed` | only the skill's name and description are in context | `add` only |
| `attested` | nothing beyond the agent's sentence | `add` only |

`call` and `read` are derived because the harness's store proves them.
`body`, `listed` and `attested` are attested because proving them means
classifying the prompt, which is heuristic and brittle in the way a denominator
cannot afford. The lowest grade is a first-class row: a skill followed from its
description produces friction like any other, and dropping it would bias the
rate.

A reader never writes an attested grade. `harvest` upgrades a row below the
grade it can prove — `attested`, `listed` or `body` to `read` or `call` — when
it finds the call that row described (§5.2), and nothing ever downgrades a
grade. A ref recorded by `add` is a claim: it never raises the grade itself,
and only the reader that finds the call does.

A derived invocation row is identified by `(machine, harness, session,
evidence_ref)` when it carries a ref, and by `(machine, harness, session,
skill, ts)` when it does not — the same composite the error rows use, so
re-harvesting an identical window writes nothing for either table.

### Error rows

`errors` records one failed tool call, derived from the harness's own store:

| Column | Meaning | Empty when |
|---|---|---|
| `id` | local row id, allocated by the store | never |
| `ts` | when the failing call started, ISO 8601 with the writer's offset | never |
| `harness` | the product whose store carried it | never |
| `session` | that harness's session id, in the same namespace as `invocations.session` | the store carried none |
| `call_id` | the harness's call or part id, opaque to the tool | the harness has no id |
| `tool` | the tool that failed | the store did not name it |
| `error_class` | the harness's own class: `tool.execution`, `aborted`, `unknown`, `provider_error` | the empty string, never the word `unknown` |
| `error_text` | the harness's message, sanitized to one line like a problem | never |
| `signature_id` | the signature row it normalizes to | never |
| `invocation_id` | the invocation it is attributed to | no attribution |
| `attribution` | `prior_in_session`, `ancestor_session` or `none` | never |
| `source` | the reader that produced it: `opencode`, `t3`, `log` | never |
| `machine` | the hostname | never |
| `fix`, `resolved_at` | the resolution contract | unresolved |

All text columns are `NOT NULL DEFAULT ''`. A row with a `call_id` is
identified by `(machine, harness, session, call_id)`; without one, by
`(harness, session, tool, ts)`. Re-harvesting an identical window writes
nothing.

An error is kept whether or not it can be attributed. Unattributed errors are
the majority in practice and they are the point: they are what a documentation
or machine-rule change fixes.

### Attribution

Attribution runs per error row, first hit wins:

1. `prior_in_session` — the latest invocation whose `session` equals the
   error's and whose `ts` is at or before the error's.
2. `ancestor_session` — the latest invocation on the nearest ancestor session
   the harness records for the error's session, at or before the error. The
   chain is walked outward, nearest first, and only when rule 1 finds nothing.
3. `none` — no candidate.

A caller that cannot see the harness's session tree attributes
`prior_in_session` or `none` and nothing else. Attribution never crosses
repositories and never rests on a bare time window: an error in one session is
not attributed to a skill run in another that merely happened nearby.

Attribution is one pure function of three inputs — the error rows, the
invocation rows and the session tree — and one module owns it. `harvest` and
`add` use that function rather than restating the rules:

- `harvest` recomputes attribution for unresolved errors in its window, with
  the session tree its reader returns.
- `add` re-attributes unresolved errors in the session it wrote whose `ts` is
  at or after the new row's, with whatever tree it can obtain. Without one it
  can only produce `prior_in_session` or `none`.

Refinement is monotone. A later pass may raise `none` to `prior_in_session` or
`ancestor_session`, and may replace a session-local attribution with an
ancestral one; nothing ever lowers an attribution back to `none`. Because the
function is pure over the rows it is given, the attribution step stays
idempotent: the same rows and the same tree produce the same answer.

### Signatures

A signature is one failure shape: the unit a single change closes.

| Column | Meaning |
|---|---|
| `id` | local row id, allocated by the store, never reused |
| `tool` | the tool the first matching error came from |
| `signature` | the normalized error text |
| `first_seen`, `last_seen` | the range of the errors that carry it, extended as each new error joins |

The unique key is `(tool, signature)`: two tools failing with the same generic
message are two shapes, and merging them would hide which tool to fix. A new
error carrying an existing signature extends `last_seen`; a resolved error
still counts in the range, because the signature records what failed, not what
is still open.

Normalization, in this order: replace absolute paths (`/…`, `~/…`) with
`<path>`; replace hexadecimal runs of seven or more characters with `<hex>`;
replace digit runs with `<n>`; collapse whitespace; strip; truncate to 110
characters. The identity is the truncated form, and the mapping is
many-to-one, computed once per error row.

The normalizer is code, not data, and it lives with the reader that runs it. A
change to it can route a new failure into a new signature; that is a split,
never a re-point. An existing signature row keeps its text and its errors, and
the rows it covers keep their resolution, so a marker naming it keeps its
meaning. Signatures are per store: nothing claims that two machines' `s12` are
the same failure, which is why a signature marker carries the machine.

### Creation, refusal and reads

- The first write creates the state directory and the file.
- An existing file that is not this schema is refused by name: "not a
  skill-log store", "an older skill-log store", or "a newer skill-log store".
  There is no half-migration and no column convergence.
- A corrupt file is named as damaged. A store another writer is holding is
  named as locked. A read never reports "no invocations logged yet" over a file
  it could not read.
- Reads create nothing. An absent store is not an error on every verb; see the
  policies below.

### Store policies

The policy, not the verb, decides what an absent, empty, damaged, foreign,
older or newer store means.

| Verb | Policy | Absent store means |
|---|---|---|
| `add`, `harvest`, `setup` | create | create it |
| `show`, `errors`, `stats` | read | the empty message, exit 0 |
| `report` | strict | refusal, exit 1, no file written |
| `report --check` | syntax | the report is still checked, exit 0 when it is well formed |
| `resolve` | write | refusal, exit 1 |
| `resolve-merged` | optional | nothing to do, exit 0 |
| `setup --check` | verify | drift, exit 1 |

`report --check` is the one exception to the strict policy: it validates the
branch's existing report and needs no store. A fresh clone or a CI job has no
store and must still check the file, so the syntax check stands alone — a
marker this store does not own is a warning, not a failure.

The store classifies and returns a typed refusal. The CLI boundary renders the
one-line message and maps the exit code; no handler inspects a SQLite error or
a store's absence on its own. The store classifies a SQLite failure the same
way on both paths: damage is damage, a lock is a lock, a file that cannot be
written is read-only ("read-only store: <path> cannot be written to"), a store
path that cannot be opened at all is unusable ("unusable store path: <path>
cannot be opened"), and anything else is the generic operational failure.

The classification never reads the caller's path: the path is stripped from
the message first, because a path can carry any word in the vocabulary and
must not choose the answer. A store named `locked` therefore cannot turn a
write refusal into a lock, and one named `older` cannot turn a read-only file
into an older schema.

### Location and overrides

- `--db`, then `SKILL_LOG_DB`, then
  `${XDG_STATE_HOME:-~/.local/state}/skill-log/skills.db`. `~` expands.
- Skills: `--skills-dir`, then `SKILL_LOG_SKILLS_DIR`, then the directory
  `setup` recorded. `add` reads it only to refuse a skill name that does not
  exist there; `setup` writes it; `skills audit` and `skills adopt` take
  `--dir` directly and never read the chain.
- Templates: `${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/`. Everything
  regenerable stays under XDG state; config the user may edit is under XDG
  config.

## 4. Context fields and adapters

Every context field resolves in this order: **explicit flag, then its
`SKILL_LOG_*` variable, then an enabled adapter, then built-in detection.**

| Field | Flag | Environment | Adapter may set |
|---|---|---|---|
| harness | `--harness` | `SKILL_LOG_HARNESS` | yes |
| session | `--session` | `SKILL_LOG_SESSION` | yes |
| parent | `--parent` | `SKILL_LOG_PARENT` | **no** |
| model | `--model` | `SKILL_LOG_MODEL` | yes |
| repo | `--repo` | `SKILL_LOG_REPO` | no (built-in git) |
| worktree | `--worktree` | `SKILL_LOG_WORKTREE` | no (built-in git) |
| project | `--project` | `SKILL_LOG_PROJECT` | yes |
| t3_thread | `--t3-thread` | `SKILL_LOG_T3_THREAD` | **no** |
| machine | `--machine` | — (hostname) | no |

- Built-in detection always runs last: `repo` and `worktree` from git,
  `machine` from the hostname, `ts` from the local clock with the writer's
  offset. Outside a git repository `repo` and `worktree` are blank, not an
  error.
- Adapters are opt-in on `add`, where they fill context fields, and never run
  by default: `SKILL_LOG_ADAPTERS=opencode` or `--adapter opencode` enables
  one. Their read side is the readers of §5.2, which run by default —
  `harvest` runs every reader whose store it can find, and the same names
  narrow that set. An adapter failure is a blank field, never an error, and an
  adapter never invents a `parent` or a `t3_thread`.
- `opencode` (1.0 target) fills `harness`, `session` from the harness
  environment, and `model` from that harness's session store, read-only.
- `t3` (optional) fills `project` from the worktree path; the thread id stays
  caller-supplied.
- `model` resolves after `session`, and `project` after `worktree`, because
  each depends on the other.
- Evidence is not a context field: `add` takes it explicitly (§5.1), `harvest`
  derives it, and no adapter may set it. The `opencode` and `t3` adapters name
  the same stores `harvest` reads, so an adapter fills one row's context and a
  harvest proves a session's evidence from the same file.

## 5. Commands

| Verb | Store policy | Section |
|---|---|---|
| `add` | create | [§5.1](#51-add) |
| `harvest` | create | [§5.2](#52-harvest) |
| `show` | read | [§5.3](#53-show) |
| `errors` | read | [§5.4](#54-errors) |
| `stats` | read | [§5.5](#55-stats) |
| `report` | strict | [§5.6](#56-report) |
| `resolve` | write | [§5.7](#57-resolve) |
| `resolve-merged` | optional | [§5.8](#58-resolve-merged) |
| `setup` | create / verify with `--check` | [§5.9](#59-setup) |
| `skills audit`, `skills adopt`, `skills template` | none | [§5.10](#510-skills) |
| `--version` | none | [§5.11](#511---version) |

### Common rules

- Every verb's `--help`, at every nesting level, ends with 2–4 real
  invocations. Usage errors reuse the same examples.
- `--dry-run` exists on every mutating verb and writes nothing; it prints the
  same shape the real run would. `skills audit` accepts it as a no-op so every
  `skills` verb has the same surface.
- `--force` is the only confirmation and no verb prompts. It overrides, per
  verb:

  | Verb | `--force` overrides | Without it |
  |---|---|---|
  | `skills adopt` | an `edited` fenced block | reported, left untouched |
  | `skills template seed` | an existing user copy | refuses |
  | `skills template reset` | existing user copies | refuses |
  | `setup` | a differing installed skill | refuses to replace it |

- Flags by verb:

  | Flag | Verbs |
  |---|---|
  | `--db` | every verb that touches the store: `add`, `harvest`, `show`, `errors`, `stats`, `report`, `resolve`, `resolve-merged`, `setup` |
  | `--json` | every verb except `--version` |
  | `--dry-run` | `add`, `harvest`, `report`, `resolve`, `resolve-merged`, `setup`, `skills adopt`, `skills template seed`, `skills template reset`, `skills audit` (no-op) |
  | `--adapter` | `add`, `harvest` |
  | `--repo`, `--skills-dir` | `setup`; `--skills-dir` also on `add` |
  | `--since` | `harvest`, `errors` take a duration; `resolve-merged` takes a reflog position |
  | `--all`, `--strict` | `harvest` |
  | `--last <n>` | `show`, `errors` |
  | `--group`, `--attribution`, `--signature`, `--tool`, `--class` | `errors` |
  | `--id` | `report`, `resolve` |
  | `--error`, `--signature` | `report` |

- Success output carries the handle the next verb needs: a marker from `add`,
  marker plus commit from `resolve`, a path from `report`.
- Problems are sanitized on read so one problem stays one line. Blank problems
  are ignored. Error text is sanitized the same way on write.
- See [§5.12](#512-json-shapes) for the stable JSON shapes.

### 5.1 `add`

Record one invocation and zero or more problems. Creates the store under the
`create` policy.

- `--skill` is required. `--problem` is repeatable; `--problem -` reads the
  text from stdin and exits 2 instead of waiting when stdin is a terminal.
- `--evidence` takes `body`, `listed` or `attested`, with `attested` the
  default. `call` and `read` are refused with exit 2: only `harvest` can prove
  them, and a self-graded row would claim what nothing checked.
- `--ref <call-id>` names the harness call this row is about. When a harvested
  row already carries that ref, the problems are appended to it and no
  invocation row is written; otherwise the row is written as `attested` with the
  ref recorded as a claim, and `harvest` raises it to `call` once it finds the
  call. A claim never raises a grade by itself.
- When `--skills-dir` or `SKILL_LOG_SKILLS_DIR` names a directory, an
  unknown skill name is refused with exit 2 — a row naming a skill that does
  not exist skews every rate it appears in.
- Context comes from §4. The timestamp is local ISO 8601 with the writer's
  offset.
- The invocation row and all problem rows commit in one transaction. A partial
  write is impossible.
- Success prints the row's marker. `--json` emits the whole row flat;
  `--dry-run` emits the same shape without writing.
- **`add` is deliberately not idempotent.** The log records occurrences; a
  retry is indistinguishable from a genuine repeat, and deduping would hide
  the second occurrence of one error. `add --help`, the bundled skills and the
  usage-log template all say so. `--ref` narrows this: the invocation is not
  duplicated, only its problems are.
- A clean run still writes a row.
- Writing a row re-attributes unresolved errors in that session (§3).

### 5.2 `harvest`

Derive invocations and errors from the harness's own store. Policy `create`.

- Readers are the read side of §4's adapters, one per harness: `opencode`
  (`session_v2`, `session_message`), `t3` (`statev2.sqlite` turn items), and
  `log` for failures that never became a tool call. `harvest` runs every
  reader whose store it can find; `SKILL_LOG_ADAPTERS` or `--adapter <name>`
  narrows the set to the names given, and a named reader that finds no store is
  a skip, not a failure. The flag enables an adapter on `add` and narrows a
  reader on `harvest`.
- An invocation is derived in two cases: a `skill` tool call becomes a row
  with evidence `call`, and a read, grep, glob or shell call naming a skill
  directory becomes a row with evidence `read`. One run is one row.
- A derived row is never written next to a row for the same run. It upgrades
  the latest matching row for the same session and skill instead, whenever that
  row's grade is below the grade the call proves: the row keeps its id, takes
  `call` or `read`, and takes the proven call id as its `evidence_ref`. So a
  `read` row becomes `call` when the same run later calls the skill, and a ref
  `add` claimed is replaced by the proof. A row already at or above the proven
  grade is left alone.
- Three guards keep the count honest: a `read` row is never written for a
  session that already has a `call` row for that skill at or before it; a
  derived row whose call id is already recorded writes nothing; and a call with
  no matching row is a new row, because two calls are two runs.
- Every failed tool call becomes an error row with a signature and an
  attribution, whether or not any skill ran (§3).
- The harness store is opened read-only and never written. A missing store is
  a skip, exit 0. A store that cannot be read — schema drift, lock,
  permissions — is a named skip, exit 0; `--strict` turns any skip into exit
  1.
- Identified per row (§3), so a second run over the same window writes
  nothing. `--since <duration>` bounds the window, `--all` scans everything,
  and the default is the last 24 hours.
- `--dry-run` writes nothing and prints the counts. `--json` emits one object
  per reader: `reader`, `invocations_added`, `upgraded`, `errors_added`,
  `errors_attributed`, `signatures_created`, `skipped` (one reason per skip,
  the same shape a skip reports on stderr).
- Recomputes attribution for unresolved errors in the window before writing, so
  a later `add` cannot leave a freshly harvested row unattributed.

### 5.3 `show`

Recent invocations with their problems, filterable, as a table for humans and
stable JSON lines for pipes. Policy `read`.

- Filters: `--skill`, `--machine`, `--harness`, `--repo`, `--run`,
  `--unresolved`, `--last`. `--run` matches a row's `session`, `t3_thread` or
  `parent`.
- A malformed argument exits 2 and names what is wrong: a non-numeric
  `--last`, which reports the 1..500 range it accepts. `--unresolved` is a
  switch and takes no value. A well-formed identifier that no row carries
  (`--skill`, `--machine`, `--harness`, `--repo`, `--run`) is valid and yields
  no rows, exit 0 — never a usage error.
- The table indents sanitized problems under their invocation and shortens the
  worktree under the home directory.
- Errors are `errors`'s job: `show` lists invocations and never mixes them in.
- An absent or empty store prints the empty message and exits 0; the JSON
  stream stays valid and empty.

### 5.4 `errors`

The error corpus and the documentation worklist. Policy `read`.

- Row mode: one line per error, newest first, with its tool, signature,
  attribution and the skill it is attributed to. Filters: `--signature`,
  `--tool`, `--class`, `--attribution`, `--skill`, `--session`, `--run`,
  `--unresolved`, `--since <duration>`, `--last`.
- `--group signature|tool|attribution|skill|session|class` switches to one row
  per cluster carrying `errors`, `unresolved`, `first_seen`, `last_seen`, and —
  for `signature` grouping — the `signature_id` to report against.
- `--attribution none` is the worklist that has no skill behind it: the errors
  a documentation or machine-rule change fixes. It is a first-class query, not
  a leftover.
- `--signature` accepts a signature id, an `s<id>` marker, or the normalized
  text itself. `--since <duration>` is the same window `harvest` takes, so a
  review can read exactly what it harvested; `--last` is the numeric count
  `show --last` takes.
- `--run` matches a row's `session`, the same namespace `show --run` matches,
  but only against `session` — not `t3_thread` or `parent`. `--session` is the
  same filter; `--run` is its name for parity with `show`.
- A well-formed filter that matches nothing yields no rows, exit 0. An unknown
  `--group` or `--attribution` exits 2 and lists the choices.
- `--json` emits the shapes in §5.12.
- An absent or empty store prints the empty message and exits 0.

### 5.5 `stats`

The denominator and the friction rate. Policy `read`.

- Counts are distinct invocations, invocations with problems, problems and
  resolved, plus problems per invocation.
- `--skill <name>` narrows the whole cut to one skill: the counts, the rate and
  the grouped rows all describe that skill alone. It is a filter, not a
  grouping key — `--by` picks what the rows are grouped by.
- `--by` accepts `skill` (default), `harness`, `model`, `repo`, `worktree`,
  `machine` and `project`. An unknown key exits 2 and lists them.
  `--by-model` remains as an alias for `--by model`.
- The grouped shape is its own; it is not the invocation row.
- Errors are never blended into these counts: the failure corpus and its
  attribution split belong to `errors --group`, and a derived failure count
  inside the invocation denominator would make both numbers mean nothing.
- An absent or empty store prints the empty message and exits 0.

### 5.6 `report`

Write the committed report listing the rows a change resolves. Policy
`strict`.

- Selection by `--id`, `--run`, `--skill`, `--error` or `--signature`. `--id`,
  `--error` and `--signature` are repeatable. Without a selector, exits 2 with
  an example — except with `--check`, which validates the branch's existing
  report and needs no selector.
- `--error` selects one error row by id or `e<id>` marker. `--signature`
  writes one marker for the whole cluster: resolution expands it to the
  unresolved error rows the store holds for that signature (§6), so one marker
  closes every row it covers and the time guard still excludes a row logged
  after the fix commit. That is how a documentation fix closes a cluster
  without one report line per error row.
- The file is `.skill-log/reports/<slug>.md`, named for the branch,
  overridable with `--slug`, written atomically.
- Ids are validated against the store; unknown ids and unknown row prefixes
  are named. Already-resolved rows are skipped and reported.
- New markers are unioned with the file's current contents. No existing marker
  is removed — including one naming another machine, which the tool never adds
  and never drops. The file is rewritten as one marker per line, sorted;
  problem text, error text and project details never appear.
- `--check` validates an existing report without writing. `--dry-run` writes
  nothing. `--json` carries the path and the markers.
- Re-running over an unchanged report prints that it is already reported.
- A checkout without the report directory falls back to trailer mode: the
  markers ride the commit body instead.

### 5.7 `resolve`

The manual escape hatch for history that was rewritten. Policy `write`.

- `--id` and `--fix` stamp one local row with a commit and the current time.
  `--id` accepts a bare id or an `e<id>` error row.
- A signature marker names a set, not a row, so `resolve` refuses it and names
  `resolve-merged` instead: expanding a set needs the per-row time guard, and
  that belongs to the hook's scan (§5.8), not to a verb that deliberately has
  none.
- It stamps once by design: no scan, no time guard, no newest-wins. Those
  belong to `resolve-merged`.
- Prints the marker plus the commit. Supports `--dry-run` and `--json`.
- An unknown id is named. A missing store is a named failure.
- A second identical call changes nothing.

### 5.8 `resolve-merged`

The hook's entry point. Policy `optional`: an absent store is nothing to do,
exit 0.

- The scan range comes from `--since` (the hook passes the pre-merge reflog
  position) and falls back to a quiet full scan when the range cannot be
  bounded.
- **Artifact mode** reads each report file's content at the commit that
  touched it, never the working tree. Uncommitted edits in a checked-out
  report must not resolve rows whose fix has not landed. A checkout without
  the report directory reads the last trailer block of each commit instead.
- The scan yields located markers: a marker plus the commit and time it came
  from.
- The scan expands a signature marker before the decision: it becomes the
  unresolved error rows the store holds for that signature, each carrying the
  signature marker's commit and time. The expansion is a query, so the marker
  written today still covers a row that arrives before the commit. A signature
  with no unresolved rows expands to nothing and is reported, reason
  `no_unresolved_rows`.
- One pure decision — no git, clock or store — then decides each located marker
  on its own:
  - the newest marker per row wins;
  - a row already stamped with the same commit is unchanged;
  - a row stamped with a different commit is **restamped**, so an amended fix
    supersedes an earlier one;
  - a row logged after the named commit is skipped, reason
    `logged_after_commit`;
  - an unknown id — including an unknown row prefix — is skipped, reason
    `unknown_id`;
  - a foreign marker is skipped, reason `foreign`, and never stamped.
- Applying the decision is the only write. Resolution is idempotent: a second
  scan stamps nothing.
- Hidden and malformed markers are reported with their ids or text in
  `ignored`, never silently dropped. Hidden means a marker line present in a
  commit body that git's last-trailer-block rule did not return.
- `--quiet`, `--dry-run` and `--json` with one stable shape that carries every
  skip reason.

### 5.9 `setup`

Make a machine and a repo ready. Idempotent. Policy `create`, except `--check`,
which is `verify`.

- Creates the store when absent and never migrates an older one.
- Installs the git `post-merge` hook in `--repo`, writing only into the
  repository's common hooks directory, refusing a file that lacks the
  ownership marker, writing atomically, and skipping a non-git checkout with a
  named reason without failing.
- Creates `.skill-log/reports/` with its README and keep file, touching
  nothing else.
- Installs both bundled skills into `--skills-dir` (see §7).
- Prints the machine identity the log will use, so an operator can see the
  spelling markers must match.
- `--check` verifies the store, the hook, the report directory and the
  installed skills, exits 1 on drift, and writes nothing.
- `--dry-run` shows the changes. `--force` replaces a differing installed
  skill. `--remove-hook` removes only a hook carrying the ownership marker.
  `--no-hook`, `--no-report-dir` and `--json` work.
- Re-running is a no-op.

The generated hook resolves the CLI at run time, in order: `command -v
skill-log`; `mise which skill-log` when `mise` is on `PATH`;
`$HOME/.local/share/mise/shims/skill-log` when executable; otherwise exit 0
silently. The resolution call is wrapped so any failure exits 0.

### 5.10 `skills`

#### `skills audit`

Read-only. Reports each skill's usage-log state and writes nothing.

- `--dir <dir>` is required. `--json` for pipes. `--dry-run` is accepted and
  changes nothing.
- One line per skill. Exit 1 on any state other than `ok` or `vendored`, 0
  when clean.
- A directory that holds no skills is refused.
- §7 defines the states and the fence.

#### `skills adopt`

Make a repo's skills conform.

- `--dir <dir>` is required; `--dry-run`, `--json` and `--force` work.
- Appends a fenced block where none exists (state `missing`).
- Rewrites a block whose content is an older render (state `stale`).
- Rewrites a block whose content does not match its own fence hash (state
  `edited`) **only with `--force`**.
- Skips `vendored` skills entirely.
- Never touches a byte outside the fence, and never touches unfenced text —
  not even with `--force`.
- Idempotent: a second run changes nothing.

#### `skills template`

Subcommands, not mode flags:

- `show [--json]` prints both effective templates, their source, their hashes,
  and whether the shipped default has moved since the user copy was seeded. It
  is also how a skill outside the swept directory gets its block: the printed
  usage-log template is the snippet to paste, placeholders included.
- `seed [--force] [--dry-run]` copies the shipped defaults into the user
  directory. Without `--force` it refuses to overwrite an existing copy.
- `reset [--force] [--dry-run]` deletes the user copies and returns to the
  shipped defaults, which the next `adopt` re-renders. It refuses while copies
  exist unless `--force` is given.

### 5.11 `--version`

Prints the release version baked in at build time.

### 5.12 JSON shapes

One flat object per row, one stable object per outcome. Every key below is
part of the contract; no verb adds or drops keys between runs.

**The invocation object** is emitted by `add` and `show`, and by either with
`--dry-run`. Its keys are `id`, `ts`, `skill`, `evidence`, `evidence_ref`,
`harness`, `session`, `parent`, `model`, `repo`, `worktree`, `project`,
`t3_thread`, `machine`, `fix`, `resolved_at`, `marker`, `problems` (an array of
strings). A `--dry-run` preview carries `id: null` and an empty `marker`: the
row does not exist yet, so it has no id and no marker.

**The error object** is emitted by `errors` in row mode. Its keys are `id`,
`ts`, `harness`, `session`, `call_id`, `tool`, `error_class`, `error_text`,
`signature`, `signature_id`, `invocation_id`, `attribution`, `skill`, `source`,
`machine`, `fix`, `resolved_at`, `marker`. `skill` repeats the attributed
invocation's name and is empty when attribution is `none`.

| Verb | Shape |
|---|---|
| `add` | one invocation object |
| `harvest` | one object per reader: `reader`, `invocations_added`, `upgraded`, `errors_added`, `errors_attributed`, `signatures_created`, `skipped` |
| `show` | one invocation object per row |
| `errors` | one error object per row; with `--group`, one object per cluster: `group`, `errors`, `unresolved`, `first_seen`, `last_seen`, plus `signature_id` and `marker` when grouping by `signature` |
| `stats` | `invocations`, `with_problems`, `problems`, `resolved`, `problems_per_invocation`, plus the grouping column named by `--by` |
| `report` | `path`, `markers`, `already_resolved` (markers), `already_reported`, `dry_run`, `trailer` |
| `report --check` | `path`, `markers`, `problems`, `warnings` |
| `resolve` | `id`, `marker`, `skill`, `fix`, `resolved_at`, `changed`, `dry_run` |
| `resolve-merged` | `resolved` (markers), `unchanged` (markers), `skipped` (objects of `row` and `reason`), `ignored` (hidden and malformed marker text), `dry_run` |
| `setup` | one object per artifact examined: `artifact` (`store`, `hook`, `report_dir`, `skills`), `status` (`created`, `updated`, `unchanged`, `drift`, `skipped`), `detail` |
| `skills audit` | one object per skill: `skill`, `path`, `state` |
| `skills adopt` | one object per skill: `skill`, `path`, `state`, `action` (`appended`, `rewritten`, `unchanged`, `refused`, `skipped`) |
| `skills template show` | `templates`: one object per template — `name`, `source`, `content`, `template_hash`, `content_hash`, `moved` |
| `skills template seed`, `reset` | `path`, `action` (`seeded`, `would_seed`, `refused`, `deleted`, `would_delete`, `absent`) |

`resolve-merged` skip reasons are exactly `unknown_id`, `foreign`,
`logged_after_commit` and `no_unresolved_rows`.

## 6. Markers and reports

- A marker is a value: `machine#row`, parsed and formatted in one place, never
  assembled by hand. The row is a bare id for an invocation, `e<id>` for an
  error row, or `s<id>` for a signature.
- An id with no machine, a placeholder, an empty machine, an id of 0 and an
  unknown row prefix are refused, never guessed at.
- A signature marker names a set, not a row: it expands at resolution time to
  the unresolved error rows the store holds for that signature, and each of
  those is then decided on its own (§5.8). The expansion is a query, so the
  marker written today still covers a row that arrives before the commit — and
  the time guard still keeps it from covering one that arrives after.
- In a commit body markers are comma-separated in the `Skill-log-Fix` trailer.
  In a report file they are one per line.
- Report files live under the repo's report directory, are named for the
  branch (overridable), and are committed with the change.
- The report format is plain text and versionless: a report written by any
  version is readable by any version.
- The commit that carried the report file — or last changed it in the scanned
  range — is the fix commit, and that commit is the stamp.
- Artifact mode is decided per checkout by the presence of the report
  directory. In artifact mode the report files are read at the commit that
  touched them and a commit trailer is ignored and reported once. In trailer
  mode the last trailer block of the commit body is the report.
- Hidden markers are reported with their ids. Malformed marker lines are
  reported with their text. Neither is dropped silently.
- Reports are kept after resolution as the audit ledger: which change closed
  which rows. Pruning is not automatic.

## 7. Skills and templates

Two templates, both overridable by the user:

| Template | Renders into |
|---|---|
| `usage-log.md` | the fenced block adopted into every skill |
| `skill-friction-review.md` | the review skill's body, installed by `setup` |

Resolution: `--template-dir`, then `SKILL_LOG_TEMPLATE_DIR`, then the user
directory, then the defaults shipped in the binary.

Placeholders: `<name>` (the skill's name) and `<command>` (the resolved binary
path). `usage-log.md` requires both, and `audit` rejects a template that lacks
`<name>` or an invocation of `<command> add` — a typo there would silently stop
every skill from logging. The review template requires `<command>`. A
placeholder may not sit next to a quote character: the tool quotes a
placeholder's value itself, and a template that quoted the placeholder would
nest the two, so the value would reach the shell where a shell expands it.

The rendered block is shell source: the reader copies a command line out of
it and runs it. So a substituted value is shell-quoted on every command line
— single quotes, with an embedded quote closed, escaped and reopened — and
left plain in prose. A command line is one that starts a command: the
placeholder is the first thing on the line after the indentation, or it
follows a markdown list item's label and colon. A skill named
`alpha; touch /tmp/pwned` therefore renders a command line that runs the
skill and nothing else.

The default template is expected to change between releases. The default moving
never touches a user copy: the state directory records the hash of the shipped
default each copy was seeded from, and `audit` and `setup --check` name it and
print the two commands that adopt it (`skills template seed --force`, then
`skills adopt`). Only a human runs that, and only to discard their own wording.
The binary carries no list of previous defaults.

### The fence

Every adopted block is delimited and self-describing:

```
<!-- skill-log:usage-log template=<hash> hash=<hash> -->
## Usage log
...
<!-- /skill-log:usage-log -->
```

`template` is the hash of the template source that rendered the block; `hash`
is the hash of the block's content. If the fence's `hash` matches the content,
the block is exactly as some version rendered it. If the content differs from
the current render, it is stale. If the recomputed hash does not match the
fence, someone edited the block.

### States

| State | Meaning | `adopt` does |
|---|---|---|
| `ok` | fence hash matches content, content matches the current render | nothing |
| `missing` | no fenced block | append a fenced block |
| `stale` | fence is intact but the content is an older render — the template moved | rewrite the block |
| `edited` | content does not match its own fence hash — hand-edited inside the fence | rewrite only with `--force` |
| `vendored` | skill carries a vendor stamp | skip entirely |

Unfenced text is user-owned and is not classified at all: the tool never reads,
matches, rewrites or deletes it. A skill that has usage-log text but no fence
is `missing`, and adoption appends a fenced block; reconciling the old section
is a human task. An opening fence whose closing line never comes is `edited`:
its content cannot be proven, so audit reports it and adoption rewrites it only
with `--force`.

The vendor stamp is a frontmatter `metadata:` block carrying a `source:` key.
Such a skill is skipped entirely: its wording belongs to its upstream, not to
this tool. The stamp is recognised by its shape, not by a YAML parser — a
`source:` key at the start of a line inside a frontmatter `metadata:` block.

### Bundled skills

`setup --skills-dir` installs two skills:

- **`skill-log`** — read and report. Copied as-is: `show`, `stats`,
  `show --json` for pipes, the model and machine cuts, and the rule that a
  reader never calls `add`. A version stamp makes the installed copy
  identifiable, and it is the only provenance for the copied skill.
- **`skill-friction-review`** — the review session. Rendered from its template
  with the resolved binary path, followed by the usage-log block rendered for
  `skill-friction-review`, so the review logs its own runs like every other
  skill. Customising it means editing the template, not the installed file.

A differing existing copy is left alone unless `--force`. `setup --check`
verifies both.

The review session's contract:

- **Input**: `harvest --since` first, so the window is complete, then `stats`,
  `show --unresolved --json` and `errors --group signature --json` over the same
  bounded window — unresolved rows by default, or the last N invocations.
- **Clustering, not listing**: the same failure repeated across runs is one
  theme with several markers, and the theme is what gets fixed. An error
  signature is already a cluster; it does not need to be found again.
- **Classification**: an instruction that contradicts reality, a missing step,
  a missing tool, a harness rule that blocks the workflow (a permission rule, a
  subagent depth, a model gate), or environment noise. The first four are
  actionable; noise is recorded as such rather than "fixed" with a workaround.
  A signature whose attribution is `none` is usually the second or third kind,
  and its fix often lives in a machine rule or a doc rather than in a skill.
- **Decisions**: fix the skill text now, fix a doc or machine rule, file an
  issue for a larger change, or leave it. It may edit skills and open issues.
  It never marks rows resolved — only the merge hook does that, and only after
  the change lands.
- **Output**: a short report per theme — evidence markers, what it decided,
  what changed. When it lands a change, it writes the `report` file for it,
  naming a signature where one change covers a whole cluster.
- **Itself**: it writes the same usage-log row as any other skill.

The review skill is deliberately not a linter. The log records friction the
agent noticed at run time; the review decides what that friction means, which
is the one thing no query can answer.

**Division of duties:** the template decides what gets logged; the review
session decides how the log gets read. Neither changes the other's contract.

## 8. Distribution and build

- **Language**: Go. The module is `github.com/Dahep/skill-log`; the
  toolchain is pinned as a mise tool and locked in `mise.toml`. The module
  targets the Go version named in `go.mod`.
- **Storage**: SQLite through `modernc.org/sqlite`, a pure-Go driver. No cgo,
  no C toolchain, no vendored copy and no live dependency: the module
  versions are pinned in `go.mod` and `go.sum`, and an upgrade is a
  deliberate `go get`.
- **The SQLite implementation is compiled into the binary.** There is no
  system SQLite to find, no library to bundle and no loader path to get
  wrong. The tool's SQL stays inside the ordinary SQLite subset the driver
  implements: where a row's stamp is turned into epoch seconds it is
  `strftime('%s', ...)`, which SQLite 3.37 has, rather than `unixepoch()`,
  which 3.38 added.
- **Artifact**: one release archive, installable with mise's `github:` backend:

  ```
  skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz
  ├── skill-log              # one statically linked executable
  ├── LICENSE                # this project's MIT licence
  ├── THIRD-PARTY-NOTICES.md # notices of everything linked into the binary
  └── NOTICE-LICENSES/       # the licence texts those notices point at
  ```

  The executable is built with `CGO_ENABLED=0`, so it carries no dynamic
  dependency at all: no `lib/` directory, no rpath and no runtime libraries.
  The archive holds the binary and the licence and notice files, and
  nothing else — never the tests or the source tree.

- **Versioning**: semantic versioning, release tag `vX.Y.Z`; `--version` is
  baked in at build time from the tag with
  `-ldflags "-X github.com/Dahep/skill-log/internal/cli.version=$VERSION"`.
  The build takes the version from `SKILL_LOG_VERSION`, else
  `git describe --tags`, else `0.0.0-dev`; it is never written into the
  checkout.
- **Platform**: `x86_64-unknown-linux-gnu` only for 1.0. The artifact is
  static, so it carries no glibc floor from a bundled library; the Go
  runtime's own requirements are the only floor.
- The binary must run on a machine with no Go toolchain and no system
  SQLite, and must translate any storage failure into one named stderr line
  and exit 1 — never a Go panic or stack trace.
- **Release workflow**: tag-triggered; install the pinned toolchain, build
  with `CGO_ENABLED=0 go build`, `tar czf`, sha256, create the release,
  upload, attach a provenance attestation.
- **Deliverables**: the binary, the two bundled skills, and a short operator
  guide. Consumer integration instructions are documentation, not code.
- **Hand-written infrastructure**: subcommand dispatch; the help renderer;
  the JSON writer; marker and report parsing; the resolution plan. The clock,
  the hostname, the process runner and the SQLite driver are standard-library
  or module calls. [ADR-0001](docs/adr/0001-go-binary-and-sqlite.md) records
  why.

### Migration

- The store is created on first write, never inherited or converted. Moving a
  machine's existing rows is a machine-setup task, not a conversion.
- Rollback is `mise uninstall skill-log`; the store is untouched.

## 9. Testing

- **One primary seam: the installed CLI.** Tests invoke the binary as a
  process against a sandboxed `HOME`/XDG state, temporary git repositories, and
  no network. They assert stdout, stderr, exit codes, the store's rows and
  files on disk. They do not import internals, so the suite survives internal
  change.
- **One clock injection**: `SKILL_LOG_NOW` fixes the time for the cases that
  need it (the resolution time guard), so the behavior is provable through the
  CLI rather than by writing the store directly. It is test-only and
  documented as such.
- **Write contention** is exercised with a real second process holding a write
  lock, not another injection variable. The bounded retry budget is what the
  case asserts.
- **The artifact is self-contained.** The build is `CGO_ENABLED=0 go build`,
  so the executable links no SQLite library and no other shared object: there
  is no system SQLite to be found and no bundled copy to be the right one.
  The write, read and resolve paths all run against the driver compiled into
  the binary, so a query the release cannot answer fails the gate.
- **Coverage that the contract names**: the store matrix (absent, empty,
  damaged, foreign, older, newer) per verb; an adapter off by default;
  flag-over-adapter precedence; repo and worktree inside, outside and across
  linked worktrees; the deliberate non-idempotency of `add`; all five document
  states; the restamp-on-differing-commit rule; a foreign marker; hidden and
  malformed marker reports; `report --check` without a selector; uncommitted
  report edits not resolving rows; a non-git checkout; a missing or older CLI
  in the hook; a time guard across differing writer offsets.
- **The error contract, against a fixture harness store**, never a live one:
  harvest twice over one window and the second run writes nothing; harvest with
  no `--adapter` and no `SKILL_LOG_ADAPTERS` runs every reader whose store
  exists, and `--adapter` narrows it to one; the fixture file is byte-identical
  after a harvest, and a read-only copy of it is accepted; a drifted fixture is
  a named skip, exit 0, and exit 1 under `--strict`; an error row and an
  inflated denominator for a read-then-call session, which must stay one row;
  the attribution matrix
  (`prior_in_session`, `ancestor_session`, `none`, an error before any skill,
  an error in a session with no skill, an error two ancestors up, an error in
  another repository never attributed); an attribution raised by a later pass
  and never lowered, with `add` and `harvest` agreeing on the rows both can
  see; a `body`, `listed` or `attested` row
  upgraded in place by the matching call or read, once, and a claimed
  `evidence_ref` upgraded when its call arrives; a normalized text mapping two
  messages to one signature and two tools with the same text to two;
  `add --evidence call` refused with exit 2; an unknown row prefix reported as
  `unknown_id`; a signature marker resolving its rows and skipping the one
  logged after the commit; `errors --attribution none` returning the
  unattributed corpus rather than an empty set.
- **Packaging test**: install the release archive into a clean container with
  no toolchain and no system SQLite, run `--version` and `setup --dry-run`,
  and assert the artifact is statically linked — the loader has no dynamic
  dependency to resolve, so there is no bundled copy that could be the wrong
  one.
- A good test fails when observable behavior changes and passes for any
  internal structure that preserves the contract. No assertions on private
  functions, no timing sleeps except where the contract is second-granular.

## 10. Deferred and out of scope

Out of scope for 1.0, recorded as intent rather than behavior:

- **Multi-machine consolidation**: `sync`, an aggregate store, merged copies
  and owner authority. Rows still carry `machine`, because the marker grammar
  needs it and an external consolidator does too. The user's own setup handles
  consolidation; reintroducing it here is a new design, not a flag.
- **A JSON parser / import path**, for reading another store's export.
- **Readers beyond the three 1.0 ships** (`opencode`, `t3`, `log`): a new
  harness is a new reader, which is the same shape as a new adapter.
- **Mining reasoning traces** for friction the agent never wrote down. The
  store holds the failure, not the intent, and a transcript-sized text scan per
  review is a different product.

Out of scope:

- Cross-machine signature identity: two stores' `s12` are unrelated, and
  merging error corpora is the same design as `sync`.
- Writing anything into the harness store — annotating its rows, retrying its
  calls, or patching its schema. It is read-only input, and an upgrade would
  clobber a write.
- Editing documentation or machine rules automatically. A signature names the
  cluster; the review session decides the change.
- A UI, dashboard, web service or hosted sync.
- Multi-user stores, permissions or tenancy; one user per machine.
- Windows and non-POSIX shells.
- Automatic selection of which rows a change fixes; that remains judgment.
- Encrypting or redacting problem text; the report never carries it.
- Pruning or compacting report files.
- A rebase or `post-rewrite` hook; rebase pulls are documented as manual.
- A peers or config file; `report` selection stays explicit.
- Forge APIs; the transport is git content.
- macOS, aarch64, musl and static builds for 1.0.
- A custom store format.
