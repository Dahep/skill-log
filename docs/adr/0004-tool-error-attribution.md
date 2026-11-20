# ADR-0004: tool-error evidence and attribution

**Status:** accepted, 2026-11-20.
**Amends:** ADR-0002's invocation shape (two columns, one grade ladder);
ADR-0003's seven-module map (an eighth module, three extended); the marker
grammar in #1; and 1.0's scope: derived records move in, transcript mining
stays out.
**Reference measurement:** the user's own store and harness transcript, read
2026-11-20 on `omarchy`. Numbers below are from that read.
**Current rules:** [SPEC.md](../../SPEC.md) §3, §5.2, §5.4, §6.

## Context

The product's thesis is that friction is worth counting, and that the count is
worthless without a denominator. Both halves assumed the agent is the
instrument: every run writes one `add`, the row is the truth, and the review
session reads rows.

Measured against the transcript it claims to describe, the instrument drifts:

| Check | Result |
|---|---|
| Invocation rows | 226 |
| `skill` tool calls in the harness store | 750 (Mar–Nov) |
| Rows matching a real call by session and skill | 62 |
| Rows whose session never called that skill | 158 |
| …of those: a read of the skill file (proof, with a call id) | 64 |
| …of those: skill body text in the run's context | 21 |
| …of those: only the name and description in context | 71 |
| …of those: a skill name that does not exist | 2 |

The 158 are not fabrications. 64 are agents hand-reading `SKILL.md` instead of
calling the skill — 44 of 55 `ui-review` rows, and 46 of the 64 are subagents
(`runner-worker` 23, `review-and-ship`'s reviewers 12). 71 are runs that
followed a skill from the description alone. Those are real invocations, and
they are exactly the ones where the harness records least.

The second half is worse. Friction that never becomes a sentence is invisible
to `add`, and it is the majority:

| Tool-call failures in the same transcript | 1,675 of 105,604 |
|---|---|
| In a session with no skill invocation at all | 1,035 (62%) |
| With a skill call earlier in the same session | 556 |

And they cluster hard, into shapes a single change closes:

| Shape | Count |
|---|---|
| `edit`: oldString not found | 157 |
| `edit`: oldString and newString identical (pure retry) | 74 |
| `read`: file not found | 87 |
| `task`: subagent depth limit reached | 40 |
| permission denials (`bash` 49, `edit` 24, `write` 18) | 91 |
| `apply_patch`: expected lines not found | 53 |
| schema-invalid arguments (`filePath`, `pattern`, `command`, `format`) | 60 |
| `webfetch`: non-2xx | 39 |
| cancelled, aborted, interrupted | 107 |

None of those need an agent's opinion to be worth fixing. The `task` cluster is
a configuration conflict: the skill suite says "spawn subagents" and the
harness refuses depth 1. The permission clusters name the exact rule that
denied them. The `webfetch` rows name stale URLs. These are documentation and
machine-rule defects that the self-report loop cannot see, because nothing in
it ever looks at a failed call.

## Decision

1. **Errors are derived, not reported.** Two tables join the 1.0 schema:
   `errors` (one failed tool call) and `signatures` (one failure shape). Only
   `harvest` writes them; `add` never does. The store is unreleased, so they
   are part of the first schema rather than a migration.

2. **An invocation carries its evidence.** `invocations` gains `evidence` and
   `evidence_ref`:
   - `call` — a `skill` tool call; ref is its call id. Derived.
   - `read` — a read, grep, glob or shell call naming a skill directory; ref is
     its call id. Derived.
   - `body` — the skill's body text is in the run's context. Attested.
   - `listed` — only the name and description are in context. Attested.
   - `attested` — nothing beyond the agent's sentence.

   The ladder is ordered and monotone: harvest upgrades an attested row to
   `call` when it finds the call that row described, and nothing downgrades.
   `add --evidence call|read` is refused, because a self-graded row would claim
   what nothing checked.

3. **`harvest` is a verb.** It reads the harness store read-only through the
   same adapters §4 already names (`opencode`, `t3`, plus a `log` reader for
   failures that never became a tool call), and writes invocations and errors.
   Idempotent by `(machine, harness, session, call_id)` for rows that have one
   and `(harness, session, tool, ts)` for rows that do not. A missing store is
   a skip; an unreadable one is a named skip; `--strict` turns a skip into
   failure. It never writes the harness store.

4. **Attribution is local, ordered and re-derivable.** Per error row, first hit
   wins: `prior_in_session` (latest invocation in the same session at or before
   the error), then `ancestor_session` (nearest ancestor session the harness
   records, same time rule), then `none`. Never a bare time window; never
   across repositories. Attribution is recomputed for unresolved rows in the
   harvest window, and by `add` for the session it wrote, because the row set
   it reasons over can grow after the first pass.

5. **A signature is allocated, not hashed.** One row per `(tool, normalized
   text)` in a store, created on first sight and never re-pointed. Normalizing
   is code; a change to it can split a shape into two signatures, and the
   existing row keeps its errors, its text and its resolution.

6. **The marker grammar gains row prefixes.** `machine#<id>` stays an
   invocation; `machine#e<id>` is an error row; `machine#s<id>` is a signature.
   Every report written before this change keeps its meaning, and the format
   stays versionless.

7. **A signature marker names a set.** `report --signature` writes one marker
   for a cluster; resolution expands it to the unresolved rows the store holds
   for that signature and applies the existing per-row rules — newest wins, the
   time guard, restamp. The expansion is a query, so a row logged before the
   landing commit is covered and one logged after is not.

8. **The unattributed corpus is a first-class query.** `errors --attribution
   none` is the documentation worklist, not a leftover, and `stats` never
   blends a derived failure count into the invocation denominator.

9. **One new module, three extended.** ADR-0003's map grows a `Reader`:
   `read(source, window) → { invocations, errors, skipped }`, the only place a
   harness schema is named, returning data and never SQL or a message. `Marker`
   gains a row kind (`id`, `e<id>`, `s<id>`) and refuses an unknown prefix in
   the same place it already refuses a bare id. `Store` gains the error and
   signature operations and keeps SQL inside itself. `Resolution` expands a
   signature marker to rows before applying its existing pure rules, so the
   decision stays pure and gains no store access.

## Why this shape

- **The objective half of every row was always derivable, and it was being
  retyped.** Session, model, timing and the call itself are in the harness
  store; the drift above is what retyping them costs.
- **A grade beats a yes/no.** The 158 rows are not noise and not proof: they
  are five different strengths of evidence. Storing the grade keeps them in the
  denominator without letting a `listed` run look like a `call` run.
- **The denominator has to be honest in both directions.** Dropping
  unprovable rows biases the rate toward harness-instrumented runs; counting
  everything at face value lets one agent's optimistic memory inflate it.
- **A cluster is the unit a change closes.** 74 identical no-op edits are one
  decision, not 74; a signature row gives that decision a name, a count and a
  marker.
- **Errors without skills are the point, not an edge case.** 62% of the corpus
  has no invocation behind it, and it is the part that points at documentation
  and machine rules rather than at skill text.
- **Read-only is the only safe coupling.** The harness store is another
  product's private schema. Reading it degrades to a blank; writing it breaks
  on the next upgrade.

## Consequences

**Positive**

- The invocation denominator is measured instead of asserted, and every row
  says how strongly it is proven.
- Tool failures are counted, clustered and attributed without agent
  cooperation, so the review session starts from evidence rather than memory.
- A documentation or machine-rule fix closes a whole cluster with one marker.
- The `read` route exposes a real harness friction — a skill loaded by hand
  instead of through the tool — that the self-report loop cannot see.

**Negative**

- The store grows four tables and a second writer path, and `harvest` needs a
  trigger: the review session runs it, and scheduling it otherwise is machine
  setup, not the tool.
- Two columns on `invocations` and a grade ladder make every consumer that
  reads rows decide what to do with a `listed` row.
- The marker grammar gains prefixes, so every parser of markers must handle
  three row forms; the report format stays readable but is no longer
  "`machine#` plus digits".
- Signature ids are per store, so a cluster cannot be compared across machines
  and a doc fix that lands here does not close the same shape there.
- A normalizer change splits shapes, which can leave two rows where one used
  to be; the older one keeps its history and resolution.

## Enforced by

- A fixture harness store is harvested twice and the second run writes nothing;
  the fixture file is byte-identical afterwards.
- The attribution matrix: error before any skill in its session is `none`; an
  error in a subagent session with the skill in the parent is
  `ancestor_session`; two ancestors up is found; an error in another
  repository's session is never attributed.
- An attested row is upgraded in place exactly once, and a second harvest does
  not add a second row.
- Two messages differing only in paths and ids share a signature; two tools
  emitting the same text do not.
- `add --evidence call` exits 2.
- A signature marker resolves its rows, skips the one logged after the commit,
  and reports an unknown prefix as `unknown_id`.
- `errors --attribution none` returns the unattributed corpus; on a store with
  no errors it prints the empty message and exits 0.

## Alternatives rejected

- **Record errors as `problems` rows.** Loses the tool, the class and the call
  id; mixes a derived fact with agent prose; and the message must stay verbatim
  to be clusterable, which problem text deliberately is not.
- **Attribute by time window alone.** Cheap, and wrong in both directions: it
  attaches another session's failures to a skill and misses the subagent chain.
- **Hash the normalized text as the signature id.** Small and stateless, but a
  normalizer change silently re-points every existing marker, and the report
  format promises it does not.
- **One marker per error row for a documentation fix.** 74 lines in a report
  for one change, and rows that arrive before the commit are not covered.
- **Have the agent pass the error text to `add`.** Reintroduces the unreliable
  instrument for a fact the harness already stores exactly.
- **Write annotation rows back into the harness store.** Breaks read-only
  trust, and a harness upgrade would clobber them.
- **Harvest `body` and `listed` by scanning prompts.** The probe works — 21 of
  the 158 were provable that way — but it is heuristic, expensive per session,
  and asks the tool to classify prompt content it does not own. The agent can
  attest the grade instead.
- **Mine reasoning traces for friction nobody wrote down.** A different product
  with a different cost model; the store records the failure, not the intent.
