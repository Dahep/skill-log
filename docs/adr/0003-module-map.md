# ADR-0003: the module map behind the CLI

**Status:** accepted, 2026-11-12.
**Current rules:** [SPEC.md](../../SPEC.md).

## Context

The CLI is the public surface, while the rules it implements are shared by
several verbs. Store classification, context precedence, marker formatting,
generated-text state and output shapes each need one owner so they are not
re-derived in command handlers.

The implementation is organized around that ownership. The packages below
separate domain work from the CLI boundary while keeping the user-visible
contract in [SPEC.md](../../SPEC.md).

## Decision

### `internal/cli`

The CLI boundary. It owns command dispatch, flag parsing, help rendering,
usage errors, exit-code mapping and the rendering of store refusals and
operational failures. It coordinates the other packages but does not own their
domain rules.

### `internal/store`

The store surface and all SQL. It owns schema creation and validation, the
refusal taxonomy (`absent`, `empty`, `damaged`, `foreign`, `older`, `newer`),
WAL, the busy timeout, the bounded retry budget and the rule that a read
creates nothing. It also owns the resolution plan: the pure decision over
located markers and stored rows that decides stamp, unchanged or skip with a
reason.

### `internal/settings`

Context and environment resolution. It owns store-path, template-directory
and skills-directory chains, the clock, hostname detection, git detection and
opt-in harness adapters. Context precedence is explicit flag, then environment,
then adapter, then built-in detection; the exact rules are in
[SPEC.md](../../SPEC.md) §4.

### `internal/document`

Generated skill text. It owns rendering a template, parsing around the fence,
classifying the document into `ok`, `missing`, `stale`, `edited` or `vendored`,
and rewriting only inside the fence. Audit, adoption, skill installation and
setup verification use this package so the fence remains the only provenance
for generated text.

### `internal/template`

Template ownership. It owns template-directory resolution, effective-template
loading and validation, the state that records the shipped default from which
a user copy was seeded, and the resolved binary path used by rendered
templates.

### `internal/format`

Shared output construction. It owns the ordered JSON object builder, the text
sanitizer, table rendering and atomic file writes. Commands may define their
own stable outcome shape, but the shared mechanics stay here.

### `internal/marker`

The marker grammar. It owns parsing and formatting `machine#id`, including
the grammar and refusal reasons for bare ids, placeholders, empty machines and
id 0. The report writer, JSON output and resolution use it; no caller assembles
marker text by hand.

### `internal/process`

Process execution. It owns running external commands and invoking git, with
typed causes for success, not-a-repository, no-commits, missing command and
command failure. Callers do not decode error strings or treat empty output as
a failure.

### `internal/assets`

The shipped default templates, embedded in the binary. It contains data, not
behavior; `internal/template` resolves and validates it.

`cmd/skill-log` is the entry point and does nothing except call the CLI
boundary.

## Invariants

- The store surface is typed. SQL remains inside `internal/store`; no command
  package builds or executes a statement.
- No package outside `internal/cli` prints to the terminal or exits the
  process. The CLI boundary owns user-visible errors, output and exit codes.
- Help text has one renderer. Verb definitions are rendered from the same
  command descriptions used by dispatch.
- Each flag has one descriptor carrying its name, type, default and help text.
  Parsing, usage output and help rendering consume that descriptor.
- The marker grammar has one owner. `internal/marker` parses and formats it.
- The resolution plan is pure. It has no git, clock or store dependency; the
  store applies the plan and writes the result.
- Generated text is changed only through `internal/document`, and only inside
  the fence.
- Context precedence and adapter opt-in behavior have one owner in
  `internal/settings`; [SPEC.md](../../SPEC.md) §4 defines the contract.

## Why this shape

- Ownership follows the rule, not the verb. Each package exists where several
  verbs would otherwise re-derive the same decision.
- Purity where the risk is. The resolution decision cannot corrupt a store by
  accident when it has no git, clock or store dependency.
- One seam keeps tests stable. The installed CLI is the public behavior
  surface; internal package boundaries can change without changing the
  contract.
- The fence remains the only provenance for generated text. Centralizing
  document handling prevents one path from reading or rewriting user-owned
  text.

## Consequences

- A new verb reuses store policy, marker formatting, context precedence and
  output construction rather than restating those rules.
- A change to a shared contract has one package to inspect, with the
  user-visible rule still stated in [SPEC.md](../../SPEC.md).
- The resolution decision can be exercised independently from external
  processes and time.
- Package boundaries require the CLI boundary to coordinate work that remains
  expressed through one public command surface.
