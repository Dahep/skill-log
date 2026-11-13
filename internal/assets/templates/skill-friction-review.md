---
name: skill-friction-review
description: Review the local skill invocation log and turn its friction into change — cluster problems into themes, separate instruction defects from environment noise, and decide what to fix.
---

# Skill friction review

Review the skill invocation log and turn its friction into change. The
commands below are the resolved binary; the log is the local one.

- **Input**: <command> stats and <command> show --unresolved --json over
  a bounded window — unresolved rows by default, or the last N
  invocations.
- **Clustering, not listing**: the same failure repeated across runs is
  one theme with several markers, and the theme is what gets fixed.
- **Classification**: an instruction that contradicts reality, a missing
  step, a missing tool, or environment noise. Only the first three are
  actionable; noise is recorded as such rather than "fixed" with a
  workaround.
- **Decisions**: fix the skill text now, file an issue for a larger
  change, or leave it. It may edit skills and open issues. It never
  marks rows resolved — only the merge hook does that, and only after
  the change lands.
- **Output**: a short report per theme — evidence markers, what it
  decided, what changed. When it lands a change, it writes the `report`
  file for it.
- **Itself**: it writes the same usage-log row as any other skill.

The review is deliberately not a linter. The log records friction the
agent noticed at run time; the review decides what that friction means,
which is the one thing no query can answer.