# CONTEXT

Project vocabulary and invariants for skill-log. Read this before adding a
command, a column, or a report field.

## Purpose

Record every agent-skill invocation and the friction it produced, keep the
record local, and close friction by naming the change that fixed it.

## Glossary

- **Invocation row** — one skill run: when, which skill, model, project,
  threads, worktree, machine.
- **Problem row** — one piece of friction attached to an invocation. Problems
  are separate rows, so invocation count stays the denominator of the
  problems-per-invocation rate.
- **Marker** — `machine#id`. The only way a row is named from outside the
  store. The machine is required because ids are per store.
- **Owner** — the machine whose store wrote a row. Copies keep the owner's
  machine and id.
- **Aggregate** — a store that has merged other machines' rows.
- **Sync** — merging another machine's store into this one over SSH. One-way:
  the aggregate pulls, never pushes.
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
  block adopted into every skill, and `skill-friction-review.md`, the review
  skill's body. A user copy under XDG config wins over the shipped default.
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

## Invariants

- The owner is authoritative. A mirrored copy is never resolved in place, and
  sync always takes the owner's fix and resolved-at values forward.
- The report never carries problem text or project details — only machine
  names and local ids.
- Newest marker wins; scanning newest commit first makes an amended fix
  supersede an earlier one.
- A row whose timestamp is after the named commit is skipped: a rebuilt log
  that reused ids must not stamp the wrong row.
- Resolution is idempotent. A second scan stamps nothing and changes nothing.
- Reads never create the state directory, an empty database, or a missing
  store. Inspecting a machine does not change it.
- A damaged store is named as damaged; a foreign SQLite file is refused.
- The post-merge hook never changes a pull's exit status, and resolves the CLI
  at run time (it cannot assume a mise shim is on `PATH`).
- The template decides what gets logged; the review session decides how the log
  is read. Neither changes the other's contract.
- A skill's usage-log block is rendered from the user's template inside a
  fence. The tool never edits a byte outside the fence, and never overwrites a
  hand-edited block without `--force`.
- One CLI, one store, no daemon, and no network beyond SSH sync.

## Boundaries

Out of scope: a UI or hosted service, multi-user stores, Windows,
non-POSIX shells, automatic selection of which rows a change fixes, encrypting
problem text, pruning reports, a rebase hook, a peers/config file, forge APIs,
and — for 1.0 — macOS, aarch64 and musl builds.
