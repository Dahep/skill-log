# CONTEXT

Project vocabulary for skill-log: what the terms mean, not what the rules are.

- **The rules live in [`SPEC.md`](SPEC.md).** If a behavior question can be
  answered by a rule, the answer is there; this file only names the things the
  rule talks about.
- **The reasoning lives in [`docs/adr/`](docs/adr/).** A decision's why, and
  what was rejected, is an ADR.
- **The work lives in issues.** Acceptance criteria and blockers only.

Read this before adding a command, a column or a report field: a new concept
needs a name here, and a new rule needs a line in `SPEC.md`.

## Glossary

- **Invocation row** — one skill run: when, which skill, harness, session,
  parent, model, repo, worktree, project, machine, and its resolution.
- **Problem row** — one piece of friction attached to an invocation, carrying
  the agent's own sentence about what went wrong. Problems are separate rows,
  so invocation count stays the denominator of the problems-per-invocation
  rate.
- **Harness** — the agent product that ran the skill (`opencode` today, later
  others). Its session id is recorded verbatim and is opaque to the tool.
- **Adapter** — opt-in code that fills context fields from a known harness's
  local state (`opencode` fills the session and model, `t3` fills the project).
  It never overrides an explicit flag and never runs by default.
- **Marker** — `machine#id`, held as a value: parsed and formatted in one
  place, never assembled by hand. The only way a row is named from outside the
  store; the machine is required because ids are per store. A marker naming
  another machine is **foreign**.
- **Located marker** — a marker plus the commit and time it was read from.
  Only the scan produces it, and only the resolution plan consumes it.
- **Resolution plan** — the pure decision over located markers and stored
  rows: stamp, unchanged, or skip with a reason. Applying the plan is the only
  write.
- **Store policy** — how a verb treats the store: create, read, strict, write,
  optional, or verify.
- **Document** — generated skill text as one module sees it: rendered from a
  template, parsed around its fence, classified into one state, and rewritten
  inside the fence only.
- **Report** — the committed file listing the rows a change resolves. In a
  repo without a report directory, the commit-body trailer is the report.
- **Resolution** — stamping a row with the commit that carries its fix.
- **Artifact mode** — a checkout containing the report directory resolves from
  report files. A checkout without it resolves from trailers.
- **Hidden marker** — a marker line present in a commit body that git's
  last-trailer-block rule did not return.
- **Fix commit** — the commit that carried the report file (or last changed it
  in the scanned range). That commit is the stamp.
- **Template** — user-owned markdown rendered by the tool: `usage-log.md`, the
  block adopted into every skill, and `skill-friction-review.md`, the body of
  the `skill-friction-review` skill. A user copy under XDG config wins over the
  shipped default. Placeholders: `<name>` (the skill's name) and `<command>`
  (the resolved binary).
- **Fence** — the `<!-- skill-log:usage-log ... -->` delimiters around an
  adopted block. The tool owns every byte inside it and nothing outside it. It
  carries the template hash and the content hash, which is what makes "the
  template moved" distinguishable from "a human edited this". It is the only
  provenance: text outside a fence is user-owned. States: `ok`, `missing`,
  `stale`, `edited`, `vendored`.
- **Adoption** — rendering the usage-log template into a project's skills, and
  keeping them in step with it: `skills audit` reports, `skills adopt` writes.
- **Review session** — the `skill-friction-review` skill reading logged
  problems, clustering them into themes, and deciding what to fix. It reads the
  log; it never writes a resolution.
