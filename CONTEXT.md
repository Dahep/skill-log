# CONTEXT

Project vocabulary and invariants for skill-log. Read this before adding a
command, a column, or a report field.

## Purpose

Record every agent-skill invocation and the friction it produced, keep the
record local, and close friction by naming the change that fixed it.

## Glossary

- **Invocation row** — one skill run: when, which skill, harness, session,
  parent, model, repo, worktree, machine.
- **Problem row** — one piece of friction attached to an invocation, carrying
  the agent's own sentence about what went wrong. Problems are separate rows,
  so invocation count stays the denominator of the problems-per-invocation
  rate.
- **Harness** — the agent product that ran the skill (`opencode` today, later
  others). Its session id is recorded verbatim and is opaque to the tool.
- **Adapter** — opt-in code that fills context fields from a known harness's
  local state (`opencode` fills the session and model, `t3` fills the project).
  It never overrides an explicit flag, never runs by default, and fails to a
  blank field rather than an error.
- **Marker** — `machine#id`. The only way a row is named from outside the
  store. The machine is required because ids are per store.
- **Report** — the committed file listing the rows a change resolves. In a
  repo without a report directory, the commit-body trailer is the report.
- **Resolution** — stamping a row with the commit that carries its fix.
- **Artifact mode** — a checkout containing the report directory resolves from
  report files. A checkout without it resolves from trailers.
- **Hidden marker** — a marker line present in a commit body that git's
  last-trailer-block rule did not return. Reported with its ids; never
  silently dropped.
- **Fix commit** — the commit that carried the report file (or last changed it
  in the scanned range). That commit is the stamp.
- **Template** — user-owned markdown rendered by the tool: `usage-log.md`, the
  block adopted into every skill, and `skill-friction-review.md`, the body of
  the `skill-friction-review` skill. A user copy under XDG config wins over the
  shipped default. Placeholders: `<name>` (the skill's name) and `<command>`
  (the resolved binary). The review skill's installed body is its template
  rendered, followed by the usage-log block for `skill-friction-review`, so the
  review logs its own runs.
- **Fence** — the `<!-- skill-log:usage-log ... -->` delimiters around an
  adopted block. The tool owns every byte inside it and nothing outside it.
  The fence carries the template hash and the content hash, which is what makes
  "the template moved" distinguishable from "a human edited this".
- **Adoption** — rendering the usage-log template into a project's skills, and
  keeping them in step with it: `skills audit` reports, `skills adopt` writes.
- **Review session** — the `skill-friction-review` skill reading logged
  problems, clustering them into themes, and deciding what to fix. It reads the
  log; it never writes a resolution.

## Store and config

- Store: `${XDG_STATE_HOME:-~/.local/state}/skill-log/skills.db`.
- Templates: `${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/`.
- Store location overrides: `--db`, then `SKILL_LOG_DB`.
- Template resolution: `--template-dir`, then `SKILL_LOG_TEMPLATE_DIR`, then
  the user directory, then the shipped defaults.
- Before rendering, `audit` rejects a `usage-log.md` that lacks `<name>` or an
  invocation of `<command> add`: a typo there would silently stop every skill
  from logging.

## Invariants

- One store per machine: 1.0 has no sync, no aggregate and no merged copies.
  Rows still carry `machine`, which the marker grammar and any external
  consolidator need.
- An adapter's value never beats an explicit flag or `SKILL_LOG_*` variable;
  an adapter failure is a blank field, not an error.
- The report never carries problem text or project details — only machine
  names and local ids.
- Newest marker wins; scanning newest commit first makes an amended fix
  supersede an earlier one.
- A row whose timestamp is after the named commit is skipped: a rebuilt log
  that reused ids must not stamp the wrong row.
- Resolution is idempotent. A second scan stamps nothing and changes nothing.
- Reads never create the state directory, an empty database, or a missing
  store. Inspecting a machine does not change it.
- A damaged store is named as damaged; a foreign or older store is refused by
  name. The store is created, never inherited or converted.
- The post-merge hook never changes a pull's exit status, and resolves the CLI
  at run time (it cannot assume a mise shim is on `PATH`).
- The template decides what gets logged; the review session decides how the log
  is read. Neither changes the other's contract.
- A skill's usage-log block is rendered from the user's template inside a
  fence. The tool never edits a byte outside the fence, and never overwrites a
  hand-edited block or converts an unfenced one without `--force`.
- A moved default template is reported, never applied. The state directory
  records the hash of the default each user copy was seeded from; `audit` and
  `setup --check` name it and print the two commands that adopt it. Every
  release that changes the default carries the previous one in the binary's
  known-templates list.
- One CLI, one store, no daemon, and no network.

## Boundaries

Out of scope: a UI or hosted service, multi-user stores, Windows,
non-POSIX shells, automatic selection of which rows a change fixes, encrypting
problem text, pruning reports, a rebase hook, a peers/config file, forge APIs,
multi-machine consolidation (`sync`, an aggregate store, merged copies — the
user's own setup handles it), and — for 1.0 — macOS, aarch64, and musl or
static builds.

Two #1 boundaries are amended, not dropped: editing other skills' files is now
in scope through `skills adopt` (still printing the snippet for skills outside
the swept directory), and the compiled rewrite it excluded is ADR-0001.
