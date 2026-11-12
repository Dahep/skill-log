"""The two shipped default templates, embedded in the binary.

The build only compiles `src/skill_log/`, so the defaults are Mojo
string constants, not resource files. There are two, and each one is the
single source of its own wording:

- `usage-log.md` — the fenced block adopted into every skill. It teaches
  the one silent write at the end of a run, the `--problem` form, the
  `machine#id` marker grammar, the read commands (`show`, `stats`), the
  fact that `add` is deliberately not idempotent, and the rule that a
  missing binary is skipped silently. It is harness-neutral: it names no
  agent product.
- `skill-friction-review.md` — the review session's body, installed by
  `setup`: the contract's input, clustering, classification, decisions,
  output and self-logging bullets, rendered with the resolved command.

Both use the `<name>` / `<command>` placeholders. A template is copied
verbatim into the user directory by `skills template seed`, and the
state directory records the hash of the shipped default each copy was
seeded from, so a moved default can be *reported* without ever touching
the user's copy.

The wording below is the contract's, not a paraphrase: the usage-log
block is what every skill's run ends with, and the review body is what
the review session is.
"""

# The template names, in the order every command lists them.
comptime USAGE_LOG_NAME = "usage-log.md"
comptime REVIEW_NAME = "skill-friction-review.md"


def template_names() -> List[String]:
    """The two template names, in canonical order."""
    var names = List[String]()
    names.append(USAGE_LOG_NAME)
    names.append(REVIEW_NAME)
    return names^


def shipped_usage_log() -> String:
    """The shipped `usage-log.md`, as it is embedded in the binary."""
    return """\
## Usage log

The skill's work ends with exactly one silent write to the local skill
log: run <command> once, at the end, with no narration and nothing else
changed on its account:

    <command> add --skill <name>

When the run surfaced problems or friction — an ambiguous step, an
instruction that conflicts with reality, a missing tool — pass each
finding in its place:

    <command> add --skill <name> \\
        --problem "<what struggled or cost the run, one sentence>" \\
        --problem "<second finding, one flag per finding>"

A clean run still lands its row, problem-less: the invocation count is
the denominator of the problems/invocation rate. Add `--t3-thread <id>`
when the T3 thread id is in context; the invocation date, project,
opencode thread id, worktree, and machine are auto-detected by the tool.

`add` is deliberately not idempotent: the log records occurrences, so a
retry after a crashed run is indistinguishable from a genuine repeat.
Two identical calls write two rows.

Read the log back through the same command: `show` for recent
invocations and their problems, `show --run <id>` for one run, `stats`
and `stats --by <column>` for counts and the problems/invocation rate,
`report` and `resolve` to name and stamp the rows a change fixes. A row
is named `machine#id` — the machine plus the invocation id — and that
marker is what every later command speaks. A reader never calls `add`.

When <command> does not exist, skip the write silently and carry on:
the skill's work outranks its own reporting."""


def shipped_review() -> String:
    """The shipped `skill-friction-review.md`, as it is embedded in the
    binary."""
    return """\
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
which is the one thing no query can answer."""


def shipped_template(name: String) raises -> String:
    """The shipped default called `name`.

    An unknown name is an error rather than an empty string: every
    caller names one of the two, and a silent empty default would render
    an empty block.
    """
    if name == USAGE_LOG_NAME:
        return shipped_usage_log()
    if name == REVIEW_NAME:
        return shipped_review()
    raise Error("unknown template: " + name)
