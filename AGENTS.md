# AGENTS.md

skill-log — a local log of agent-skill invocations: one row per run, plus the
problems that cost it, so friction can be counted, attributed to a skill, and
closed by a specific change. Domain language lives in `CONTEXT.md`; design
decisions in `docs/adr/`.

## Agent skills

### Issue tracker

GitHub Issues on `Dahep/skill-log`, accessed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. Per the `domain-modeling` skill.

### Model pins

Subagent dispatch must name an explicitly pinned seat — a bare `task` call silently inherits the parent's model. The dispatch roster, billing split, and per-seat pins live in the machine-wide agent rules (`~/.config/opencode/AGENTS.md`, stowed from the dotfiles repo); pinned seat defs live in `~/.config/opencode/agent/*.md`. Pin changes belong to the `model-rotation` skill, never to ad-hoc edits.
