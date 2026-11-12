# skill-log — specification

**Status:** normative, 1.0. This file is the single source of truth for what
skill-log does. It replaces the contract that lived in issues #1 and #3, both
of which are closed as historical records.

**How the documents divide:**

| Document | Answers | Changes by |
|---|---|---|
| `SPEC.md` (this file) | What the tool does: commands, flags, exit codes, store, markers, reports, resolution, skills, setup, distribution, testing | PR that edits this file |
| `docs/adr/` | Why each shape was chosen, and what was rejected | New ADR |
| `CONTEXT.md` | Vocabulary and invariants | PR |
| Issues | Work items with acceptance criteria and blockers | Issue edits |

An issue body is never the specification. A rule that exists only in a ticket
is a ticket bug.

---

## 1. Purpose

Record every agent-skill invocation and the friction it produced, keep the
record local, and close friction by naming the change that fixed it.

The product is one loop, and every command is a step in it:

1. **Adopt** — a repo's skills are swept so each one ends its run with a row.
   `skills audit` reports, `skills adopt` writes. `setup` installs the two
   bundled skills where the agent reads skills.
2. **Record** — every skill invocation ends with one `add`: when, which skill,
   harness, session, parent, model, repo, worktree, project, machine, and zero
   or more problems. A clean run still writes; the invocation count is the
   denominator.
3. **Review** — the bundled `skill-friction-review` skill reads the friction,
   groups it by skill and theme, separates instruction defects from
   environment noise, and decides what to fix. This is the only step that
   needs judgment, and nothing automates it.
4. **Name** — the change that addresses those problems runs
   `report --run <id>` (or `--id`, or `--skill`). That writes
   `.skill-log/reports/<slug>.md` listing the markers it addresses — machine
   names and local ids only — and the file is committed with the change. In a
   repo without a report directory, the same markers ride a commit trailer.
5. **Close** — `setup` installed a post-merge hook. When the fix lands, the
   hook runs `resolve-merged`, which stamps each named row with the commit
   that carried the report and the time.

## 2. Scope and invariants

- One CLI, one store per machine, no daemon, no network.
- The CLI is the public surface. The store schema and the report format are
  contracts, not APIs.
- A marker is `machine#id`. The machine is required because ids are per store.
- A marker naming another machine is **foreign**: reported, never stamped.
  There is no owner lookup and no cross-machine resolution in 1.0.
- Reports carry machine names and local ids only — never problem text or
  project details.
- Newest marker wins. A row whose timestamp is after the named commit is
  skipped. Resolution is idempotent.
- Reads never create the state directory, an empty database, or a missing
  store.
- The store is created, never inherited or converted. A damaged, foreign or
  older file is refused by name.
- The fence is the only provenance for generated skill text. Text outside a
  fence is user-owned and is never read, matched, rewritten or deleted.
- The post-merge hook never changes a pull's exit status.
- Exit codes: `0` success or nothing to do, `1` operational failure, `2` usage.
  Exactly one stderr line per failure, no tracebacks. JSON goes to stdout only.

`CONTEXT.md` defines the vocabulary these rules use. Read it before adding a
command, a column or a report field.

## 3. Data model and store

### Schema

Two tables, `PRAGMA user_version = 1`, `PRAGMA journal_mode = WAL`,
`PRAGMA foreign_keys = ON`, a busy timeout on connect, and a bounded
whole-attempt retry budget for writes.

`invocations`:

| Column | Meaning | Empty when |
|---|---|---|
| `id` | local row id, allocated by the store | never |
| `ts` | ISO 8601 with the writer's offset | never |
| `skill` | the invoked skill's name | never |
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
one type.

`problems` is keyed `(invocation_id, ordinal)`, carries one sentence of
friction per row, and cascades with its invocation. Problems are separate rows
so invocation count stays the denominator of the problems-per-invocation rate.
A run with two distinct frictions has two problems; a clean run has none.

`origin_id` and the unique `(machine, origin_id)` index do not exist in 1.0.
They existed to make multi-machine merging idempotent, and merging left scope
(ADR-0002).

### Creation, refusal and reads

- The first write creates the state directory and the file.
- An existing file that is not this schema is refused by name: "not a
  skill-log store", "an older skill-log store", or "a newer skill-log store".
  There is no half-migration and no column convergence.
- A corrupt file is named as damaged. A read never reports "no invocations
  logged yet" over a file it could not read.
- Reads create nothing. An absent store is not an error on every verb; see the
  policies below.

### Store policies

The policy, not the verb, decides what an absent, empty, damaged, foreign,
older or newer store means.

| Verb | Policy | Absent store means |
|---|---|---|
| `add`, `setup` | create | create it |
| `show`, `stats` | read | the empty message, exit 0 |
| `report` | strict | refusal, exit 1, no file written |
| `resolve` | write | refusal, exit 1 |
| `resolve-merged` | optional | nothing to do, exit 0 |
| `setup --check` | verify | drift, exit 1 |

The store classifies and returns a typed refusal. The CLI boundary renders the
one-line message and maps the exit code; no handler inspects a SQLite error or
a store's absence on its own.

### Location and overrides

- `--db`, then `SKILL_LOG_DB`, then
  `${XDG_STATE_HOME:-~/.local/state}/skill-log/skills.db`. `~` expands.
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
- Adapters are opt-in and never run by default. `SKILL_LOG_ADAPTERS=opencode`
  or `--adapter opencode` enables one. An adapter failure is a blank field,
  never an error, and an adapter never invents a `parent` or a `t3_thread`.
- `opencode` (1.0 target) fills `harness`, `session` from the harness
  environment, and `model` from that harness's session store, read-only.
- `t3` (optional) fills `project` from the worktree path; the thread id stays
  caller-supplied.
- `model` resolves after `session`, and `project` after `worktree`, because
  each depends on the other.

## 5. Commands

Common rules:

- Every verb accepts `--db`.
- Every verb's `--help`, at every nesting level, ends with 2–4 real
  invocations. Usage errors reuse the same examples.
- `--dry-run` exists on every mutating verb and writes nothing. It prints the
  same shape the real run would.
- `--force` is the only confirmation and no verb prompts. It has one meaning
  in skill adoption (see §7); elsewhere it guards overwriting a copy the tool
  did not write.
- Success output carries the handle the next verb needs: a marker from `add`,
  marker plus commit from `resolve`, a path from `report`.
- `--json` is one flat object per row or one stable object per outcome. A
  caller never has to guess which keys a run carries.
- Problems are sanitized on read so one problem stays one line. Blank problems
  are ignored.

### `add`

Record one invocation and zero or more problems. Creates the store under the
`create` policy.

- `--skill` is required. `--problem` is repeatable; `--problem -` reads the
  text from stdin and exits 2 instead of waiting when stdin is a terminal.
- Context comes from §4. The timestamp is local ISO 8601 with the writer's
  offset.
- The invocation row and all problem rows commit in one transaction. A partial
  write is impossible.
- Success prints the row's marker. `--json` emits the whole row flat;
  `--dry-run` emits the same shape without writing.
- **`add` is deliberately not idempotent.** The log records occurrences; a
  retry is indistinguishable from a genuine repeat, and deduping would hide
  the second occurrence of one error. `add --help`, the bundled skills and the
  usage-log template all say so.
- A clean run still writes a row.

### `show`

Recent invocations with their problems, filterable, as a table for humans and
stable JSON lines for pipes. Policy `read`.

- Filters: `--skill`, `--machine`, `--harness`, `--repo`, `--run`,
  `--unresolved`, `--last`. `--run` matches a row's `session`, `t3_thread` or
  `parent`.
- The table indents sanitized problems under their invocation and shortens the
  worktree under the home directory.
- `--json` emits one flat object per row with every column, the `marker`, and
  the `problems` array.
- An absent or empty store prints the empty message and exits 0; the JSON
  stream stays valid and empty.
- An invalid filter value exits 2 and lists the valid choices.

### `stats`

The denominator and the friction rate. Policy `read`.

- Counts are distinct invocations, invocations with problems, problems and
  resolved, plus problems per invocation.
- `--by` accepts `skill` (default), `harness`, `model`, `repo`, `worktree`,
  `machine` and `project`. An unknown key exits 2 and lists them.
- JSON carries the same columns as the table, flat, with the grouping column
  included. The grouped shape is its own; it is not the invocation row.
- An absent or empty store prints the empty message and exits 0.

### `report`

Write the committed report listing the rows a change resolves. Policy
`strict`.

- Selection by `--id`, `--run` or `--skill`; no selector exits 2 with an
  example.
- The file is `.skill-log/reports/<slug>.md`, named for the branch,
  overridable with `--slug`, written atomically.
- Ids are validated against the store; unknown ids are named. Already-resolved
  rows are skipped and reported.
- New markers are unioned with the file's current contents. Problem text and
  project details never appear.
- `--check` validates an existing report without writing. `--dry-run` writes
  nothing. `--json` carries the path and the markers.
- Re-running over an unchanged report prints that it is already reported.
- A marker naming another machine is never written.
- A checkout without the report directory falls back to trailer mode: the
  markers ride the commit body instead.

### `resolve`

The manual escape hatch for history that was rewritten. Policy `write`.

- `--id` and `--fix` stamp one local row with a commit and the current time.
- It stamps once by design: no scan, no time guard, no newest-wins. Those
  belong to `resolve-merged`.
- Prints the marker plus the commit. Supports `--dry-run` and `--json`.
- An unknown id is named. A missing store is a named failure.
- A second identical call changes nothing.

### `resolve-merged`

The hook's entry point. Policy `optional`: an absent store is nothing to do,
exit 0.

- The scan range comes from `--since` (the hook passes the pre-merge reflog
  position) and falls back to a quiet full scan when the range cannot be
  bounded.
- Artifact mode reads report files from the checkout. A checkout without the
  directory reads the last trailer block of each commit.
- The scan yields located markers: a marker plus the commit and time it came
  from.
- One pure decision — no git, clock or store — decides each located marker:
  - the newest marker per row wins;
  - a row already stamped with the same commit is unchanged;
  - a row stamped with a different commit is **restamped**, so an amended fix
    supersedes an earlier one;
  - a row logged after the named commit is skipped with a reason;
  - an unknown id is reported;
  - a foreign marker is reported as `foreign` and never stamped.
- Applying the decision is the only write. Resolution is idempotent: a second
  scan stamps nothing.
- Hidden and malformed markers are reported with their ids, never silently
  dropped. Hidden means a marker line present in a commit body that git's
  last-trailer-block rule did not return.
- `--quiet`, `--dry-run` and `--json` with one stable shape that carries every
  skip reason.

### `setup`

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
- `--dry-run` shows the changes. `--remove-hook` removes only a hook carrying
  the ownership marker. `--no-hook`, `--no-report-dir` and `--json` work.
- Re-running is a no-op.

The generated hook resolves the CLI at run time, in order: `command -v
skill-log`; `mise which skill-log` when `mise` is on `PATH`;
`$HOME/.local/share/mise/shims/skill-log` when executable; otherwise exit 0
silently. The resolution call is wrapped so any failure exits 0.

### `skills audit`

Read-only. Reports each skill's usage-log state and writes nothing.

- `--dir <dir>` is required. `--json` for pipes. `--dry-run` is accepted and
  changes nothing.
- One line per skill. Exit 1 on any state other than `ok` or `vendored`, 0
  when clean.
- A directory that holds no skills is refused.
- §7 defines the states and the fence.

### `skills adopt`

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

### `skills template`

Subcommands, not mode flags:

- `show [--json]` prints both effective templates, their source, their hashes,
  and whether the shipped default has moved since the user copy was seeded.
- `seed [--force] [--dry-run]` copies the shipped defaults into the user
  directory. Without `--force` it refuses to overwrite an existing copy.
- `reset [--force] [--dry-run]` deletes the user copies and returns to the
  shipped defaults, which the next `adopt` re-renders. It refuses while copies
  exist unless `--force` is given.

### `--version`

Prints the release version baked in at build time.

## 6. Markers and reports

- A marker is a value: `machine#id`, parsed and formatted in one place, never
  assembled by hand.
- A bare id, a placeholder, an empty machine and id 0 are refused, never
  guessed at.
- In a commit body markers are comma-separated in the `Skill-log-Fix` trailer.
  In a report file they are one per line.
- Report files live under the repo's report directory, are named for the
  branch (overridable), and are committed with the change.
- The commit that carried the report file — or last changed it in the scanned
  range — is the fix commit, and that commit is the stamp.
- **Artifact mode** is decided per checkout by the presence of the report
  directory. In artifact mode the report files are read and a commit trailer is
  ignored and reported once. In trailer mode the last trailer block of the
  commit body is the report.
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
every skill from logging. The review template requires `<command>`.

The default template is expected to change between releases. The default moving
never touches a user copy: the state directory records the hash of the shipped
default each copy was seeded from, and `audit` and `setup --check` name it and
print the two commands that adopt it (`skills template seed --force`, then
`skills adopt`). Only a human runs that, and only to discard their own wording.
The binary carries no list of historical defaults.

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
is a human task.

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

- **Input**: `stats` and `show --unresolved --json` over a bounded window.
- **Clustering, not listing**: the same failure repeated across runs is one
  theme with several markers, and the theme is what gets fixed.
- **Classification**: an instruction that contradicts reality, a missing step,
  a missing tool, or environment noise. Only the first three are actionable;
  noise is recorded as such rather than "fixed" with a workaround.
- **Decisions**: fix the skill text now, file an issue for a larger change, or
  leave it. It may edit skills and open issues. It never marks rows resolved —
  only the merge hook does that, and only after the change lands.
- **Output**: a short report per theme — evidence markers, what it decided,
  what changed. When it lands a change, it writes the `report` file for it.
- **Itself**: it writes the same usage-log row as any other skill.

The review skill is deliberately not a linter. The log records friction the
agent noticed at run time; the review decides what that friction means, which
is the one thing no query can answer.

## 8. Distribution and build

- **Language**: Mojo 1.2, toolchain pinned as a mise tool (`pypi:mojo@1.2.0`),
  locked in `mise.toml`.
- **Storage**: SQLite through `ehsanmok/sqlite` v0.2.2 (MIT), vendored as
  `vendor/sqlite/ffi.mojo` + `db.mojo` with the upstream commit and license
  recorded. No ORM layer, no `morph`, no live dependency. Upgrades are a
  deliberate copy-forward.
- **Artifact**: one release archive, installable with mise's `github:` backend:

  ```
  skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz
  ├── skill-log            # patchelf --set-rpath '$ORIGIN/lib'
  └── lib/
      ├── libKGENCompilerRTShared.so
      ├── libMSupportGlobals.so
      ├── libAsyncRTRuntimeGlobals.so
      └── libsqlite3.so.0
  ```

- **Platform**: `x86_64-unknown-linux-gnu` only for 1.0. glibc floor is the
  release runner's; no musl or static build is possible through `mojo build`.
- The bundled `libsqlite3.so.0` is built or fetched against the release
  runner's glibc, never taken from a development machine. The binary must load
  the bundled copy, and must translate a load failure into one named stderr
  line and exit 1 — never a Mojo traceback.
- `--version` is baked in at build time from the release tag.
- **Release workflow**: tag-triggered; install the pinned toolchain, `mojo
  build -I vendor`, `patchelf`, `tar czf`, sha256, create the release, upload,
  attach a provenance attestation.
- **What is hand-written**, because the ecosystem does not provide it:
  subcommand dispatch; local dates (ISO 8601 with the writer's offset and
  parsing `git log --format=%cI`) through libc `localtime_r`/`strftime`;
  process execution with an exit status through `fork`/`exec`/`wait` via FFI;
  the JSON writer (the tool writes JSON and never parses it); marker and
  report parsing.

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
- **Coverage that the contract names**: the store matrix (absent, empty,
  damaged, foreign, older, newer) per verb; an adapter off by default;
  flag-over-adapter precedence; repo and worktree inside, outside and across
  linked worktrees; the deliberate non-idempotency of `add`; all five document
  states; the restamp-on-differing-commit rule; a foreign marker; the hidden
  and malformed marker reports; `report --check`; a non-git checkout; a
  missing or older CLI in the hook.
- **Packaging test**: install the release archive into a clean container with
  no toolchain and no system SQLite, run `--version` and `setup --dry-run`,
  and assert the bundled SQLite is the one loaded.
- **Parity gate**: the reference implementation's harness cases run against
  the installed binary, with the intentionally changed commands adapted and
  case names kept comparable, plus the cases the new contract needs.
- A good test fails when observable behavior changes and passes for any
  internal structure that preserves the contract. No assertions on private
  functions, no timing sleeps except where the contract is second-granular.

## 10. Deferred and out of scope

Deferred, recorded as intent rather than 1.0 behavior:

- **Multi-machine consolidation**: `sync`, an aggregate store, merged copies
  and owner authority. Rows still carry `machine`, because the marker grammar
  needs it and an external consolidator does too. Reintroducing consolidation
  is a new design, not a flag.
- **A JSON parser / import path**, for reading another store's export.

Out of scope:

- A UI, dashboard, web service or hosted sync.
- Multi-user stores, permissions or tenancy; one user per machine.
- Windows and non-POSIX shells.
- Encrypting or redacting problem text; the report never carries it.
- Pruning or compacting report files.
- A rebase or `post-rewrite` hook; rebase pulls are documented as manual.
- A peers or config file; `report` selection stays explicit.
- Forge APIs; the transport is git content.
- macOS, aarch64, musl and static builds for 1.0.
- A custom store format.

## 11. History

Issue #1 defined the product contract for the extraction from dotfiles. Issue
#3 defined the Mojo rewrite. ADR-0001, ADR-0002 and ADR-0003 amended both and
are the reasoning behind this file. All three issues stay readable as history;
this document is what governs behavior.
