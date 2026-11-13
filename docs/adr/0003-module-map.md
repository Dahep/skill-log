# ADR-0003: the module map behind the CLI

**Status:** accepted, 2026-11-12.
**Amends:** the storage, templates and skill-adoption sections of
[issue #3](https://github.com/Dahep/skill-log/issues/3); the adoption
invariants in [CONTEXT.md](../../CONTEXT.md); and the acceptance criteria of
tickets #7, #9, #10, #11, #12, #13, #14, #15, #16, #17, #18, #19 and #21.
**Current rules:** [SPEC.md](../../SPEC.md).
**Supersedes nothing.** The behavior contract moved to `SPEC.md`; this record
is the reasoning behind its module boundaries.

## Context

The spec fixes the CLI seam and leaves the modules behind it to the tickets.
The tickets are named after commands, so the rules that every command shares
have no owner: store classification appears in five tickets, the marker
grammar in its own prose, the resolution fold inside one ticket, the
generated-text state in three, and precedence in nine acceptance criteria.

The port source makes this concrete. `bin/skill-log` on dotfiles branch
`t3/e53b1745` (2,323 lines) opens the store at seven sites, funnels damage
through a boolean that only recognises corruption, hand-builds eleven JSON
objects, formats `machine#id` twice, and carries two Git wrappers with
opposite failure semantics. Spec #3 expects the statements to move across
close to verbatim, so the port would inherit that shape.

This ADR records the module map decided before the port starts, and the
semantics that changed while deciding it.

**Where the map landed.** The port is written in Go
([ADR-0004](0004-go-binary-and-pure-go-sqlite.md)), so the seven modules
below are seven packages under `internal/`: `store`, `marker`, `process`,
`settings`, `document`, `format`, and the CLI boundary `cli`. The names in
this record are the module boundaries, not the file names; the table in
[Implementation status](#implementation-status) says which Go package holds
each one and what actually shipped.

## Decision

Seven modules, none of them a verb, plus the CLI boundary #7 already owns.

### 1. Store

`Store.open(policy)` returns a store or a typed refusal. It owns the
taxonomy — `absent`, `empty`, `damaged`, `foreign`, `older`, `newer` — plus
WAL, the busy timeout, the bounded retry budget and the rule that a read
creates nothing. It owns no message text and no exit code: #7's boundary
renders the refusal and maps the code, because #7 already owns the
one-stderr-line rule.

Policies per verb:

| Verb | Policy | Absent store means |
|---|---|---|
| `add`, `setup` | create | create it |
| `show`, `stats` | read | the empty message, exit 0 |
| `report` | strict | refusal, exit 1, no file written |
| `resolve` | write | refusal, exit 1 |
| `resolve-merged` | optional | nothing to do, exit 0 |
| `setup --check` | verify | drift, exit 1 |

The surface is typed operations — `insert_invocation`, `rows(filter)`,
`problems_for(ids)`, `stamp(marker, commit, at)`, `verify` — not a
connection. SQL never leaves the module, which is what lets the resolution
plan be tested without a store.

#7 defines the module and the taxonomy; #9 adds the schema, the operations
and the first write.

### 2. Marker

`Marker { machine, id }` with `parse(text) → Marker | Invalid(reason)` and
`format(marker) → text`. Grammar and refusal wording live here: bare id,
placeholder, empty machine, id 0. The report writer, `show --json` and
resolution all use it; nobody builds `machine#id` with an f-string.

Scan data is separate: the scan yields `Located { marker, commit, epoch }`,
which only the resolution plan consumes.

### 3. Process

`run(argv) → { status, stdout, stderr }` and `git(argv) → GitResult`, whose
cause is one of `Ok`, `NotARepository`, `NoCommits`, `Missing`,
`Failed(status, stderr)`. No caller decodes an error string or treats an
empty string as a failure. Repo and worktree derivation live in the context
module that consumes these causes, not here.

### 4. Settings

One descriptor per context key declares its allowed sources and emits the
flag, the `SKILL_LOG_*` name, the help line and the precedence order from the
same row. Two passes: independent keys first, then keys that depend on
another (`model` after `session`, `project` after `worktree`). `parent` and
`t3_thread` have no adapter source by construction.

The store path, template directory and skills directory keep their own short
chains. They have different shapes and two to four lines each; folding them
in would add descriptors without removing a contract.

### 5. Resolution

`plan(located, rows) → { stamps, unchanged, skips }`, pure: no git, no clock,
no store. It decides newest-marker-per-row, unknown id, already resolved with
the same commit, restamp on a differing commit, a row logged after the named
commit, and a foreign-machine marker.

`resolve-merged` is scan → plan → apply → render. Manual `resolve` is
deliberately a different policy — it is the history-rewritten escape hatch —
and shares only `stamp()` and the idempotency rule.

Restamping on a differing commit is what makes CONTEXT's “an amended fix
supersedes an earlier one” true across scans. The old implementation stamped
once and called every later marker `unchanged`, so the invariant only held
inside a single scan.

### 6. Document

`render(template, vars) → Text + hashes`, `parse(text) → before · block ·
after`, `classify(document, texts) → State`, `rewrite(document, text)`
touching no byte outside the fence. Audit, adopt, skill install and
`setup --check` all go through it.

**The fence is the only provenance.** Five states:

| State | Meaning | `adopt` does |
|---|---|---|
| `ok` | fence intact, content is the current render | nothing |
| `missing` | no fenced block | append one |
| `stale` | fence intact, content is an older render | rewrite it |
| `edited` | content does not match its own fence hash | rewrite only with `--force` |
| `vendored` | vendor stamp | skip |

Unfenced text is user-owned. The tool never detects, matches, rewrites or
deletes it — not even with `--force`. A skill that has usage-log text but no
fence is `missing`, and adoption appends a fenced block; reconciling the old
section is a human task.

The five questions that used to look like one another stay distinct: a fence
hash mismatch means a human edited the block, a fence-intact difference from
the current render means the template moved, and the seed hash in the state
directory means the shipped default moved. One module answers them; it does
not merge them.

### 7. Output

One escaping JSON writer. The invocation row is one shape derived from the
schema, used by `add` and `show`. Aggregates (`stats`) and outcomes
(`resolve`, `report`, `resolve-merged`) keep their own small stable shapes;
forcing them into the invocation type would add descriptor machinery without
removing a contract.

### Testing

The installed CLI stays the only seam, and `SKILL_LOG_NOW` is the only clock
injection. Write contention is exercised by a real second process holding a
write lock, not a second injection variable.
`resolve-merged --dry-run --json` already exposes stamps, unchanged rows and
skip reasons, so the plan's decisions are observable through the binary. No
unit harness.

## Why this shape

- **Ownership follows the rule, not the verb.** Every module above exists at
  the point where two or more verbs would otherwise re-derive the same
  decision.
- **Purity where the risk is.** The resolution fold is the only place where a
  wrong decision corrupts history; making it a pure function is cheap and
  removes git, the clock and the hostname from the decision path.
- **Deletion over relocation.** Removing legacy detection deletes a state, a
  table of historical templates and one invariant, rather than adding a
  matcher. Treating unfenced text as invisible deletes two more states and
  the `--force` semantics that went with them.
- **One seam.** The spec's testing decision survives; what changes is that
  the clock becomes injectable instead of the internals becoming importable.

## Consequences

**Positive**

- A new verb inherits store policy, marker formatting, precedence and output
  rather than restating five rules.
- The amended-fix invariant becomes true instead of aspirational.
- The seven-state table shrinks to five, and `--force` has one meaning.
- #3's stale body text is corrected, so the next reader does not re-derive
  this ADR from contradictions.

**Negative**

- Migrating this machine appends 69 fenced blocks and leaves 69 unfenced
  `## Usage log` sections for a human to delete. Accepted: the alternative is
  the tool guessing at text it never wrote.
- `SKILL_LOG_NOW` is a test-only environment variable that a determined user
  can set; it is documented as such.
- The store module lands across two tickets (#7 and #9), so its interface must
  be defined before its schema exists.

## Enforced by

These are the checks the record is held to. Two of them name verbs the Go
port has not shipped yet — `resolve-merged` and `setup` — so they are
enforced by the contract, not yet by the binary.

- #21 runs the store matrix per verb: absent, empty, damaged, foreign, older,
  newer.
- A marker built by hand anywhere fails review; round-trip parse/format is one
  test.
- `resolve-merged --dry-run --json` carries every skip reason, including
  `foreign` and `logged after that commit`.
- `SKILL_LOG_NOW` makes the time guard provable through the CLI.
- `setup --check` after an audit on a freshly adopted skills directory is
  clean, which is the test that install and audit agree.

## Implementation status

This record was written before the port. The port is done, and it kept some of
the shape below and not all of it. What shipped, what did not, and why — so the
next reader does not take the map above for the tree as it is.

The tree is Go now ([ADR-0004](0004-go-binary-and-pure-go-sqlite.md)), so the
module names below are Go packages under `internal/`, and the file names are
the Go ones.

| § | Module | Go package | Holds |
|---|---|---|---|
| 1 | Store | `internal/store` | `store.go`, `read.go`, `write.go`, `plan.go` — the schema, the refusal taxonomy, the reads, the write and the resolution plan |
| 2 | Marker | `internal/marker` | `marker.go` — the `machine#id` grammar and its parse/format |
| 3 | Process | `internal/process` | `process.go` — `Run` and `Git` with typed causes |
| 4 | Settings | `internal/settings` | `paths.go`, `detect.go`, `clock.go`, `adapters.go` — store path, clock, machine, git detection, the opt-in adapters |
| 5 | Resolution | `internal/store` | `plan.go` — `Plan`, the pure decision; `cli/resolve.go` applies it |
| 6 | Document | `internal/document` | `document.go`, `hash.go` — parse, classify, render, rewrite around the fence |
| 7 | Output | `internal/format` | `json.go`, `text.go`, `table.go`, `files.go` — the ordered JSON object writer, the sanitizer, the shared table renderer, atomic file writes |
| — | CLI boundary | `internal/cli` | `main.go`, `cli.go`, `flags.go`, `help.go`, `render.go` and one file per verb |
| — | Templates | `internal/template` | `template.go` — template-directory resolution, effective-template loading and validation, seeded-from state, and the resolved binary path |

`internal/assets` holds the two shipped default templates, embedded into the
binary with `go:embed`. `cmd/skill-log` is the entry point and holds nothing
but `cli.Main()`.

### Shipped

- **The marker grammar is a leaf.** `internal/marker` depends on nothing and
  owns `Format(machine, id)`; the store, the resolver and the report all call
  it, so nobody builds `machine#id` by hand. The scan data (`Located`) is
  separate from the grammar, as §2 promised.
- **The resolution plan is pure.** `store.Plan(located, rows, localHost)`
  decides with no git, no clock and no store, and the writer applies what it
  decided. The newest-marker rule, the unknown id, the same-commit no-op,
  the restamp and the foreign marker are all decided in one place.
- **The store owns the taxonomy.** A refusal is a value (`Refusal`), never a
  word inside a message, and a SQLite failure is classified by the store
  (`ClassifyError`) rather than inspected by a handler — damage is damage, a
  lock is a lock. That much of §1's promise is kept.
- **The document module answers the five questions.** `Parse` splits at the
  fence, `Classify` decides the state, `Rewrite` and `Append` splice without
  touching a byte outside the fence.
- **The CLI is the only seam.** Every suite runs the installed binary as a
  process, and `SKILL_LOG_NOW` is the only clock injection.
- **The process seam exists.** `internal/process` offers `Run(dir, name,
  args...)` returning a status and both streams, and `Git(dir, args...)`
  returning a typed cause (`GitOk`, `GitNotARepository`, `GitNoCommits`,
  `GitMissing`, `GitFailed`). No caller decodes an error string to find out
  what happened. §3's promise is kept.
- **One help renderer for the verbs.** `cli.RenderVerb` renders every verb's
  usage block, and `cli.TopLevelHelp` renders the top-level one; both read
  the same `Verb` row the dispatcher holds.

### Not shipped

- **A typed store surface.** §1 says the surface is typed operations and that
  "SQL never leaves the module". The SQL does stay in the store — no verb
  builds a statement of its own, and `internal/cli` does not import
  `database/sql` at all. But the *handle* still leaves it: `store.OpenRead`
  and `store.OpenWrite` return a `*store.Store`, and the verbs hold one and
  call its methods. The taxonomy is one place, the queries are one place, and
  the handle that reaches them is a public type rather than a set of
  operations behind one. The one exception is `internal/settings`, whose
  opencode adapter opens `opencode.db` itself to read another tool's store —
  a read-only foreign database, which §1 never covered.
- **A settings descriptor table.** §4 wants one descriptor per context key,
  emitting the flag, the environment name, the help line and the precedence
  order from the same row. That table is **not adopted**. The precedence
  chain lives in `internal/cli/add.go` — `resolveField(flag, variable,
  adapterValue, detected)` — over the detections and adapters that
  `internal/settings` provides. A key is still spelled out in the verb's
  `Usage` string, in its `ValueFlags` list, in the parser and in the help
  text; the settings package holds the paths, the clock, the hostname, the
  git detection and the adapters, and no descriptor table.
- **One help renderer everywhere.** The verb table and the top-level block
  share a renderer, but `skills` builds its own blocks in
  `internal/cli/skills.go` (`subcommandHelp`), and the two disagree about
  what a block contains: the verb renderer takes its text from the `Verb`
  row, the skills blocks are literals.
- **A single-sourced schema column list.** The `invocations` column list is
  written once, in `internal/store/store.go` as `invocationColumns`, and the
  schema check reads it (`missingColumns("invocations", invocationColumns)`).
  The two readers do **not** read that list: they share one SQL constant,
  `invocationSelect`, which spells the column list out again. So the list is
  single-sourced between the schema check and the DDL's readers, and spelled
  once more in the select the readers use.

### Why

The behaviour is met and the contract holds — every promise in `SPEC.md` is
pinned by a suite, and the reviews that examined the tree found no contract
violation in any of these. What is missing is the *shape*: the same
decisions are still re-derived in more than one place, and each of the four
items above is one of them. A rewrite of the tree is out of proportion to a
behaviour that is already right, so the debt is recorded here and worked as a
separate change.

The follow-up is
[issue #26](https://github.com/Dahep/skill-log/issues/26), labelled
`ready-for-agent`: it lists the items with this section as the review
evidence, and its acceptance criteria are shape, not behaviour.

## Alternatives rejected

- **A connection plus retry helper** instead of typed operations: closer to
  the port, but SQL leaks back into every verb and the plan cannot be tested
  without a store.
- **Sharing the resolution plan with manual `resolve`**: the two policies are
  intentionally different; unifying them would either break the escape hatch
  or add a mode switch that re-creates the split.
- **A unit-test harness for the pure modules**: a second seam, and the plan's
  decisions already surface through `--dry-run --json`.
- **One unified drift mechanism** for generated text: the five questions have
  different inputs and different consequences; merging them would delete
  required states.
- **Historical-template detection for unfenced blocks**: unreliable text
  matching that rewrites bytes the tool never wrote. Removed with `legacy`.
- **Four provisioners with `ensure/verify/remove`**: only the hook has a
  removal step, so the uniform interface would be unused surface for one
  caller; `setup` stays a thin coordinator.
- **Keeping the seven-state table**: `legacy` and `unowned` only exist to
  classify unfenced text, which the tool no longer reads.
