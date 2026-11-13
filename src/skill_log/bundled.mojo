"""The two bundled skills `setup --skills-dir` installs."""

from skill_log.document import append, render, substitute
from skill_log.version import version

comptime SKILL_LOG_SKILL = "skill-log"
comptime REVIEW_SKILL = "skill-friction-review"

comptime STAMP_OPEN = "<!-- skill-log:installed version="
comptime STAMP_CLOSE = " -->"


def skill_log_body() -> String:
    """The embedded `skill-log` body, installed verbatim."""
    return """\
---
name: skill-log
description: Read the local skill invocation log — usage counts and the problems/friction tied to each skill's runs. Use when the user asks about skill usage, skill friction, "skill log", "problems per skill", or "which skills cause trouble". Writing a row is every skill's own Usage log section, not this skill.
---

# Skill log

Every skill invocation ends with one row in the local SQLite log:
invocation date, skill, harness, session, parent, model, repo, worktree,
project and machine — plus problem rows tying each finding to the
invocation that found it. The CLI owns the store; query it through the
CLI, never the db by hand. The context columns are auto-detected at add
time; blank means "unknown or not applicable", and a blank is reported
as a gap rather than guessed at.

## Reading

- Recent invocations, problems indented under each: `skill-log show`
- One skill's history: `skill-log show --skill <name> --last 5`
- One run: `skill-log show --run <id>` — the filter matches the session,
  the thread id or the parent the rows were logged under
- Unresolved rows: `skill-log show --unresolved`
- Pipes: `skill-log show --last 50 --json` emits one flat object per
  row, one stable key set (`... | jq -c 'select(.model != "")'`)
- Counts and the friction rate: `skill-log stats` — the
  problems/invocation column is the friction-per-use signal
- Cuts: `skill-log stats --by <column>` groups by skill (the default),
  harness, model, repo, worktree, machine or project; `--by-model`
  remains an alias for `--by model`. The model cut is the rotation view
  — friction per model rather than per skill — and a blank model means
  none was recorded: a gap, never a model row. The machine cut
  (`skill-log show --machine <host>`, `skill-log stats --by machine`)
  reads the rows of one host in a consolidated copy.

Every command accepts `--db <path>` for scratch copies and snapshot
reads. Done when the user's question is answered from CLI output, and
any follow-up friction question ("which of these runs struggled?") is
answered from the same rows.

## Markers

A row is named `machine#id` — the machine plus the invocation id — and
that marker is what every later command speaks. `show --json` prints
each row's `marker` in exactly that form. A bare id, a placeholder, an
empty machine and id 0 are refused, never guessed at. Every marker names
its machine, because one id means a different row in each machine's log
and the same merged commit is read on all of them.

## Fixing

The change that fixes logged friction names the invocations it resolves
in a report file committed with it:

    skill-log report --id 42 --id 43     # the rows this change fixes
    skill-log report --run <id>          # the rows one run logged
    skill-log report --skill <name>      # the rows of one skill

That writes `.skill-log/reports/<slug>.md`, named for the branch
(`--slug` overrides): one `machine#id` per line and nothing else — no
problem text, no project details. New markers are unioned with the
file's current contents, and existing lines are preserved byte-for-byte,
including a marker naming another machine: the tool never adds a
foreign marker and never removes one a previous report carried.
`skill-log report --check` validates the branch's report without a
selector; `--dry-run` writes nothing and `--json` carries the path and
the markers. The ids come from the rows — `--id` is a local invocation
id from `show` — so selection is not a memory task. A checkout without
the report directory falls back to trailer mode: the markers ride the
commit body instead, comma-separated in the `Skill-log-Fix:` trailer.

## Resolving

Resolution is a separate step, after the change lands. The `post-merge`
hook `setup` installs runs `resolve-merged` on every pull: it resolves
every report file the pull added or changed — read from the merged tree,
never from uncommitted working-tree edits — and stamps each named row
with the fix commit and the resolution time. A rebase-based pull fires
no `post-merge`, so run `skill-log resolve-merged` yourself after one.
Re-running is free.

The newest marker per row wins: a row already stamped with the same
commit is unchanged, and a row stamped with a different commit is
restamped, so an amended fix supersedes an earlier one. Three shapes are
reported and left alone — a marker this log does not have, a marker
naming another machine's row (its owner resolves it), and a row logged
after the named commit. Hidden and malformed markers are reported with
their ids or text, never dropped silently.

`skill-log resolve --id <id> --fix <commit>` is the manual escape hatch
for history that was rewritten: it stamps one local row with a commit
and the current time, and a second identical call changes nothing.
`stats` counts the resolved rows in its `resolved` column and `show`
renders the `fix` and `resolved_at` columns, so the log reads as
friction, change, resolution.

## Notes

- `add` is deliberately not idempotent: the log records occurrences, so
  a retry after a crashed run is indistinguishable from a genuine repeat
  and two identical calls write two rows. Deduping would hide the second
  occurrence of one error.
- A reader never calls `add`: reading writes nothing — `show`, `stats`
  and the report reads are that. The one write a run of this skill makes
  is its own usage-log row (below): the run logging itself, not a read.
  A user asking to correct the log's record is the only other reason
  `add` runs here.
"""


def stamp_line() -> String:
    """This build's version-stamp line, newline included."""
    return STAMP_OPEN + version() + STAMP_CLOSE + "\n"


def stamp_version(document: String) -> String:
    """The version the stamp in `document` names, or "" when there is"""
    var n = document.byte_length()
    var at = 0
    while at <= n:
        if document.find(STAMP_OPEN, at) == at:
            var rest = String(document[byte=at + STAMP_OPEN.byte_length() :])
            var cut = rest.find(STAMP_CLOSE)
            if cut < 0:
                return ""
            return String(rest[byte=0:cut])
        var newline = document.find("\n", at)
        if newline < 0:
            return ""
        at = newline + 1
    return ""


def skill_log_document(usage_template: String, command: String) raises -> String:
    """The installed `skill-log` document: body, stamp, usage-log block."""
    var rendered = render(usage_template, SKILL_LOG_SKILL, command)
    return append(skill_log_body() + "\n" + stamp_line(), rendered.text)


def review_document(
    review_template: String, usage_template: String, command: String
) raises -> String:
    """The installed `skill-friction-review` document: the review"""
    var body = substitute(review_template, REVIEW_SKILL, command)
    var rendered = render(usage_template, REVIEW_SKILL, command)
    return append(body, rendered.text)
