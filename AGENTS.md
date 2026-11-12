# AGENTS.md

skill-log — a local log of agent-skill invocations: one row per run, plus the
problems that cost it, so friction can be counted, attributed to a skill, and
closed by a specific change. Domain language lives in `CONTEXT.md`; design
decisions in `docs/adr/`.

## Build and test

- `scripts/build.sh` — the release-shaped artifact: `dist/skill-log` plus
  `dist/lib/`, rpath `$ORIGIN/lib`, the version baked in. Needs `mise` (the
  Mojo pin in `mise.toml`), `patchelf`, and a system `libsqlite3.so.0` to
  bundle.
- `scripts/test.sh` — the three suites under `tests/`, against `dist/`.
  `--build` rebuilds first. Each suite also runs on its own.
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

Single-context: root `CONTEXT.md` + `docs/adr/`. Per the `domain-modeling` skill.

### Model pins

Subagent dispatch must name an explicitly pinned seat — a bare `task` call silently inherits the parent's model. The dispatch roster, billing split, and per-seat pins live in the machine-wide agent rules (`~/.config/opencode/AGENTS.md`, stowed from the dotfiles repo); pinned seat defs live in `~/.config/opencode/agent/*.md`. Pin changes belong to the `model-rotation` skill, never to ad-hoc edits.
