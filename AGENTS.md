# AGENTS.md

skill-log — a local log of agent-skill invocations: one row per run, plus the
problems that cost it, so friction can be counted, attributed to a skill, and
closed by a specific change. The specification is `SPEC.md`; domain language
lives in `CONTEXT.md`; design decisions in `docs/adr/`.

## Specification

- `SPEC.md` is the single source of truth for behavior. An issue body is never
  the specification; a rule that lives only in a ticket is a ticket bug.
- Spec changes go through a PR that edits `SPEC.md`, never an edit to an issue
  body. Reasoning that deserves to outlive the change goes in a new ADR.
- Issues carry work items: acceptance criteria and blockers. They may cite
  `SPEC.md`; they may not restate it.

## Build and test

- `scripts/build.sh` — the release-shaped artifact: `dist/skill-log` plus
  `dist/lib/`, rpath `$ORIGIN/lib`, the version baked in. Needs `mise` (the
  Mojo pin in `mise.toml`), `patchelf`, and a system `libsqlite3.so.0` to
  bundle.
- `scripts/test.sh` — the suites under `tests/`, against `dist/`.
  `--build` rebuilds first. Each suite also runs on its own.
  `tests/packaging.sh` is the one suite the default gate leaves out: it needs
  docker, so it runs on CI and on demand, not in the offline gate.
- The suites are black-box: they run the binary as a process with a scratch
  HOME and a scratch store. `tests/lib.sh` holds the shared assertions —
  `check`, `check_contains`, `check_absent`, `check_one_line`, `tally`, and
  the JSON readers. Assert on what a case can actually distinguish: a `like
  '%a%b%'` check passes across a newline, and a `sed` field reader mangles a
  value the writer escapes, so both prove less than they look like they do.
- `bwrap` (sandbox checks) and `script` (the terminal case) are optional; a
  missing one prints a `skip` line rather than pretending it ran.

## Agent skills

### Issue tracker

GitHub Issues on `Dahep/skill-log`, accessed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `SPEC.md` + `CONTEXT.md` + `docs/adr/`. Per the `domain-modeling` skill.

### Model pins

Subagent dispatch must name an explicitly pinned seat — a bare `task` call silently inherits the parent's model. The dispatch roster, billing split, and per-seat pins live in the machine-wide agent rules (`~/.config/opencode/AGENTS.md`, stowed from the dotfiles repo); pinned seat defs live in `~/.config/opencode/agent/*.md`. Pin changes belong to the `model-rotation` skill, never to ad-hoc edits.
