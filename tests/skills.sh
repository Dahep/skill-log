#!/usr/bin/env bash
# The skills test: templates, audit, adopt, and the document states, against
# the built artifact.
#
#   tests/skills.sh
#
# It exercises tickets #17 and #18's surface: the two shipped templates,
# their resolution chain and placeholder validation, `skills template
# show|seed|reset`, `skills audit` over the five document states, and
# `skills adopt`'s append/rewrite/refuse/skip actions with their
# byte-exactness and idempotency. The cases are the promises the spec
# makes — all five states classify, a `missing` skill with stale unfenced
# text nearby leaves that text untouched, a moved shipped default is
# reported with the two adopting commands and never applied, seed/reset
# refuse without `--force` and honour `--dry-run`, an empty directory is
# refused, the audit writes nothing, adopt changes no byte outside the
# fence and a second run changes nothing, and every help block ends with
# real invocations.
#
# Fence fixtures are built through the CLI where a render exists
# (`skills template show --json` carries the template source, and the
# audit's own render is what a fresh block matches); hashes are hardcoded
# only to prove an `edited`/tampered block.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-skills}"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools python3

if [ ! -x "$BIN" ]; then
    printf 'skills.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" "$SCRATCH/config" "$SCRATCH/state"

export HOME="$SCRATCH/home"
export XDG_CONFIG_HOME="$SCRATCH/config"
export XDG_STATE_HOME="$SCRATCH/state"
unset SKILL_LOG_DB SKILL_LOG_TEMPLATE_DIR
unset SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME

TPL="$XDG_CONFIG_HOME/skill-log/templates"
SEEDED="$XDG_STATE_HOME/skill-log/seeded-from"

# run <args...>: the binary with the sandbox's environment. Output lands
# in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# count_examples <text>: the number of example invocations in a rendered
# help block — the lines under the `examples:` heading.
count_examples() {
    printf '%s\n' "$1" | sed -n '/^examples:$/,$p' | grep -c '^  ' || true
}

# ------------------------------------------- a hostile name is quoted
#
# The rendered block is shell source: the agent copies the command line
# out of it and runs it. So a skill name or a binary path that carries
# shell metacharacters must be quoted, or the block hands the reader a
# command nobody meant to write.
#
# The name below is `alpha; touch <marker>`: run the rendered line and
# the marker appears. With the name quoted, it does not — and the line
# still runs the binary.
HOSTILE="$SCRATCH/hostile"
rm -rf "$HOSTILE"
mkdir -p "$HOSTILE/skill"
MARKER="$SCRATCH/hostile-marker"
rm -f "$MARKER"
printf -- '---\nname: alpha; touch %s\ndescription: a hostile fixture\n---\n\n# Fixture\n' \
    "$MARKER" > "$HOSTILE/skill/SKILL.md"
run skills adopt --dir "$HOSTILE"
check "adopt renders a hostile skill name" "$STATUS" "0"
HOSTILE_BLOCK="$(cat "$HOSTILE/skill/SKILL.md")"
# The command line is quoted: the name stands inside single quotes, and
# the embedded quote is closed, escaped and reopened.
check_contains "the hostile name is quoted in the command line" \
    "$HOSTILE_BLOCK" "'alpha; touch $MARKER'"
check_absent "the hostile name is not interpolated bare" \
    "$HOSTILE_BLOCK" "add --skill alpha; touch"
# And the rendered line is safe to run.
CMD_LINE="$(printf '%s\n' "$HOSTILE_BLOCK" \
    | grep -m1 -- '--skill' \
    | sed 's/^[[:space:]]*//')"
printf '%s\n' "$CMD_LINE" > "$SCRATCH/hostile.cmd"
if sh "$SCRATCH/hostile.cmd" --help >/dev/null 2>&1; then
    pass "the quoted command line runs the binary"
else
    fail "the quoted command line does not run the binary: $CMD_LINE"
fi
if [ -e "$MARKER" ]; then
    fail "the quoted command line ran the injected command"
else
    pass "the quoted command line did not run the injected command"
fi

# A binary path with a space in it is quoted the same way, and the
# rendered line still runs the binary.
SPACEY="$SCRATCH/spacey bin"
rm -rf "$SPACEY"
mkdir -p "$SPACEY/lib"
cp "$BIN" "$SPACEY/skill-log"
chmod +x "$SPACEY/skill-log"
for lib in "$DIST"/lib/*.so*; do
    [ -e "$lib" ] || continue
    cp "$lib" "$SPACEY/lib/"
done
SPACEY_SKILLS="$SCRATCH/spacey-skills"
rm -rf "$SPACEY_SKILLS"
mkdir -p "$SPACEY_SKILLS/gamma"
printf 'name: gamma\n' > "$SPACEY_SKILLS/gamma/SKILL.md"
(
    cd "$SPACEY_SKILLS" || exit 1
    "$SPACEY/skill-log" skills adopt --dir "$SPACEY_SKILLS" >/dev/null 2>&1
)
SPACEY_BLOCK="$(cat "$SPACEY_SKILLS/gamma/SKILL.md")"
check_contains "a path with a space is quoted" \
    "$SPACEY_BLOCK" "'$SPACEY/skill-log'"
SPACEY_CMD="$(printf '%s\n' "$SPACEY_BLOCK" \
    | grep -m1 -- '--skill' \
    | sed 's/^[[:space:]]*//')"
printf '%s\n' "$SPACEY_CMD" > "$SCRATCH/spacey.cmd"
if sh "$SCRATCH/spacey.cmd" --help >/dev/null 2>&1; then
    pass "the quoted path with a space runs the binary"
else
    fail "the quoted path with a space does not run the binary: $SPACEY_CMD"
fi

# --------------------------------------------------------------- help

run skills --help
check "skills --help exits 0" "$STATUS" "0"
check "skills --help is the verb block" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"
check_contains "skills --help lists adopt" "$OUT" "skills adopt"
EXAMPLES="$(count_examples "$OUT")"
if [ "$EXAMPLES" -ge 2 ] && [ "$EXAMPLES" -le 4 ]; then
    pass "skills --help ends with 2 to 4 real invocations"
else
    fail "skills --help ends with 2 to 4 real invocations (got $EXAMPLES)"
fi

for sub in "audit" "adopt" "template show" "template seed" "template reset"; do
    # shellcheck disable=SC2086  # $sub is deliberately word-split: "template show" is two args
    run skills $sub --help
    check "skills $sub --help exits 0" "$STATUS" "0"
    check "skills $sub --help is the subcommand block" \
        "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"
    EXAMPLES="$(count_examples "$OUT")"
    if [ "$EXAMPLES" -ge 2 ] && [ "$EXAMPLES" -le 4 ]; then
        pass "skills $sub --help ends with 2 to 4 real invocations"
    else
        fail "skills $sub --help ends with 2 to 4 real invocations (got $EXAMPLES)"
    fi
done

run skills template --help
check "skills template --help exits 0" "$STATUS" "0"
check_contains "skills template --help lists show" "$OUT" "template show"
check_contains "skills template --help lists seed" "$OUT" "template seed"
check_contains "skills template --help lists reset" "$OUT" "template reset"

# --------------------------------------------- template show (shipped)

run skills template show --json
check "template show --json exits 0" "$STATUS" "0"
check "template show --json has the templates key" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print("templates" in json.loads(sys.stdin.read()))')" "True"
check "template show --json has two templates" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["templates"]))')" "2"
check "template show --json template keys" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read())["templates"][0].keys())))')" \
    "content content_hash moved name source template_hash"
check "the shipped usage-log source is named shipped" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["templates"][0]; print(t["source"])')" "shipped"
check "a shipped default has not moved from itself" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["templates"][0]; print(t["moved"])')" "False"

# The snippet is the usage-log template, placeholders included: it is
# what a skill outside the swept directory pastes.
run skills template show
check "template show exits 0" "$STATUS" "0"
check_contains "template show prints the pasteable snippet" "$OUT" \
    "<command> add --skill <name>"
check "template show names the source" \
    "$(printf '%s\n' "$OUT" | grep -c 'source: shipped')" "2"

# ------------------------------------------------------------- seeding

run skills template seed
check "seed writes the copies" "$STATUS" "0"
check "seed writes usage-log.md" \
    "$(test -f "$TPL/usage-log.md" && echo yes || echo no)" "yes"
check "seed writes skill-friction-review.md" \
    "$(test -f "$TPL/skill-friction-review.md" && echo yes || echo no)" "yes"
check "seed records the seeded-from hash under XDG state" \
    "$(test -f "$SEEDED/usage-log.md" && echo yes || echo no)" "yes"
check_absent "the seeded-from record is not in the config dir" \
    "$(ls "$TPL")" "seeded"

run skills template seed
check "seed refuses an existing copy without --force" "$STATUS" "1"
check "seed names the refusal" "$ERR" "skill-log: seed refused an existing copy"

run skills template seed --force
check "seed --force overwrites" "$STATUS" "0"

# A dry run previews the write and writes nothing.
rm -f "$TPL/skill-friction-review.md"
run skills template seed --force --dry-run
check "seed --dry-run exits 0" "$STATUS" "0"
check_contains "seed --dry-run says what it would write" "$OUT" \
    "skill-friction-review.md: would write $TPL/skill-friction-review.md"
check "seed --dry-run writes nothing" \
    "$(test -f "$TPL/skill-friction-review.md" && echo yes || echo no)" "no"
run skills template seed --force
check "seed --force restores the copy" "$STATUS" "0"

# The JSON shape of seed and reset (SPEC §5.10): one object per
# template, with `path` and `action`. The action vocabulary is fixed
# here, so a caller reads a value and never matches prose.
run skills template reset --force
check "reset --force clears the copies for the JSON case" "$STATUS" "0"
run skills template seed --json
check "seed --json exits 0" "$STATUS" "0"
check "seed --json emits one object per template" \
    "$(printf '%s\n' "$OUT" | grep -c '^{')" "2"
check "seed --json object keys are exactly path, action" \
    "$(json_keys "$(printf '%s\n' "$OUT" | head -1)")" "action path"
check "seed --json names the seeded path" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" path)" \
    "$TPL/usage-log.md"
check "seed --json names the seeded action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "seeded"
check "seed --json seeds both templates" \
    "$(printf '%s\n' "$OUT" | python3 -c "import json,sys; print(','.join(o['action'] for o in [json.loads(l) for l in sys.stdin if l.strip()]))")" \
    "seeded,seeded"

# A dry run previews the same shape and writes nothing.
run skills template reset --force
rm -f "$TPL/usage-log.md"
run skills template seed --json --dry-run
check "seed --json --dry-run exits 0" "$STATUS" "0"
check "seed --json --dry-run previews the action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "would_seed"
check "seed --json --dry-run writes nothing" \
    "$(test -f "$TPL/usage-log.md" && echo yes || echo no)" "no"

# The refusal is a value too, not prose.
run skills template seed --force --json
check "seed --json --force exits 0" "$STATUS" "0"
run skills template seed --json
check "seed --json refuses an existing copy" "$STATUS" "1"
check "seed --json names the refusal action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "refused"

run skills template seed --force --json
check "seed --json --force exits 0" "$STATUS" "0"

# reset has the same shape, with its own action vocabulary.
run skills template reset --json
check "reset --json refuses while copies exist" "$STATUS" "1"
check "reset --json names the refusal action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "refused"
run skills template reset --json --force
check "reset --json --force exits 0" "$STATUS" "0"
check "reset --json emits one object per template" \
    "$(printf '%s\n' "$OUT" | grep -c '^{')" "2"
check "reset --json object keys are exactly path, action" \
    "$(json_keys "$(printf '%s\n' "$OUT" | head -1)")" "action path"
check "reset --json names the deleted path" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" path)" \
    "$TPL/usage-log.md"
check "reset --json names the deleted action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "deleted"

# A template that is not there is reported as absent, not as a deletion.
run skills template reset --json --force
check "reset --json on absent copies exits 0" "$STATUS" "0"
check "reset --json names the absent action" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -1)" action)" "absent"

# The copies are back for the cases that follow.
run skills template seed --force
check "seed restores the copies for the later cases" "$STATUS" "0"

# ------------------------------------------------- moved default report

# Point the seeded-from record at a hash that is not the current shipped
# default: the copy is then "seeded from a default that has moved".
printf '0000000000000000\n' > "$SEEDED/usage-log.md"
run skills template show
check "a moved default exits 0" "$STATUS" "0"
check "a moved default is reported" \
    "$(printf '%s\n' "$OUT" | grep -c 'moved: true')" "1"
check "a moved default names seed --force" \
    "$(printf '%s\n' "$OUT" | grep -c 'skills template seed --force')" "1"
check "a moved default names adopt" \
    "$(printf '%s\n' "$OUT" | grep -c 'skills adopt')" "1"
check_absent "a moved default is never applied to the copy" \
    "$(cat "$TPL/usage-log.md")" "0000000000000000"

run skills template show --json
check "a moved default is reported in JSON" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["templates"][0]; print(t["moved"])')" "True"

# SPEC §7: `audit` names a moved shipped default too, with the two
# commands that adopt it. The name is the failure's one stderr line
# (SPEC §2: exactly one stderr line per failure), and the exit code
# says the directory is not conformant.
AUDITDIR="$SCRATCH/audit-moved"
rm -rf "$AUDITDIR"
mkdir -p "$AUDITDIR/alpha"
printf 'name: alpha\n' > "$AUDITDIR/alpha/SKILL.md"
# The skill is conformant, so the moved default is the only reason the
# audit fails.
run skills adopt --dir "$AUDITDIR"
check "the audit fixture is conformant" "$STATUS" "0"
run skills audit --dir "$AUDITDIR"
check "audit exits 1 on a moved default" "$STATUS" "1"
check_contains "audit names the moved default" "$ERR" "the shipped default moved"
check_contains "audit names seed --force" "$ERR" "skills template seed --force"
check_contains "audit names adopt" "$ERR" "skills adopt"
check_one_line "the moved-default note is one line" "$ERR"

# The same answer in JSON: the per-skill objects are unchanged, and the
# name is still on stderr.
run skills audit --dir "$AUDITDIR" --json
check "audit --json exits 1 on a moved default" "$STATUS" "1"
check_contains "audit --json names the moved default" "$ERR" \
    "the shipped default moved"
check "audit --json still emits one object per skill" \
    "$(printf '%s\n' "$OUT" | grep -c '^{')" "1"

# The record is removed, so the copy is no longer known to be behind
# and the audit is clean again.
rm -f "$SEEDED/usage-log.md"
run skills audit --dir "$AUDITDIR"
check "audit is clean again without the record" "$STATUS" "0"

# --------------------------------------------------------------- reset

run skills template reset
check "reset refuses while copies exist without --force" "$STATUS" "1"
check "reset names the refusal" "$ERR" "skill-log: reset refused while copies exist"

run skills template reset --force --dry-run
check "reset --dry-run exits 0" "$STATUS" "0"
check_contains "reset --dry-run says what it would delete" "$OUT" \
    "usage-log.md: would delete $TPL/usage-log.md"
check "reset --dry-run deletes nothing" \
    "$(test -f "$TPL/usage-log.md" && echo yes || echo no)" "yes"

run skills template reset --force
check "reset --force deletes the copies" "$STATUS" "0"
check "reset deletes usage-log.md" \
    "$(test -f "$TPL/usage-log.md" && echo yes || echo no)" "no"
check "reset deletes skill-friction-review.md" \
    "$(test -f "$TPL/skill-friction-review.md" && echo yes || echo no)" "no"
check "reset clears the seeded-from record" \
    "$(test -f "$SEEDED/usage-log.md" && echo yes || echo no)" "no"

run skills template show
check "after reset the source is shipped again" \
    "$(printf '%s\n' "$OUT" | grep -c 'source: shipped')" "2"

# ------------------------------------------------------- template dir

# A --template-dir wins over the user directory and the shipped default.
mkdir -p "$SCRATCH/custom"
printf 'custom usage-log for <name> via <command> add\n' > "$SCRATCH/custom/usage-log.md"
printf 'review for <command>\n' > "$SCRATCH/custom/skill-friction-review.md"
run skills template show --json --template-dir "$SCRATCH/custom"
check "--template-dir wins" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["templates"][0]; print(t["source"])')" \
    "$SCRATCH/custom/usage-log.md"

# SKILL_LOG_TEMPLATE_DIR is the next source.
export SKILL_LOG_TEMPLATE_DIR="$SCRATCH/custom"
run skills template show --json
check "SKILL_LOG_TEMPLATE_DIR wins when no flag" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["templates"][0]; print(t["source"])')" \
    "$SCRATCH/custom/usage-log.md"
unset SKILL_LOG_TEMPLATE_DIR

# -------------------------------------------- placeholder validation

# A usage-log template missing <name> is refused by name.
mkdir -p "$SCRATCH/broken"
printf 'run <command> add\n' > "$SCRATCH/broken/usage-log.md"
run skills template show --template-dir "$SCRATCH/broken"
check "a template missing <name> is refused" "$STATUS" "1"
check_contains "the refusal names <name>" "$ERR" \
    "skill-log: usage-log.md has no <name> placeholder"

# A usage-log template missing the <command> add invocation is refused.
printf 'for <name> only\n' > "$SCRATCH/broken/usage-log.md"
run skills template show --template-dir "$SCRATCH/broken"
check "a template missing <command> add is refused" "$STATUS" "1"
check_contains "the refusal names <command> add" "$ERR" \
    "skill-log: usage-log.md has no <command> add invocation"

# The review template needs <command>.
printf 'review with no command\n' > "$SCRATCH/broken/skill-friction-review.md"
printf 'for <name> via <command> add\n' > "$SCRATCH/broken/usage-log.md"
run skills template show --template-dir "$SCRATCH/broken"
check "a review template missing <command> is refused" "$STATUS" "1"
check_contains "the refusal names the review's <command>" "$ERR" \
    "skill-log: skill-friction-review.md has no <command> placeholder"

# ------------------------------------------------- a quoted placeholder
#
# The rendered block is shell source: the agent copies the command line
# out of it and runs it. The tool quotes a placeholder's value for that
# reason — but the tool's own quoting is single quotes, and a template
# that puts the placeholder inside its own double quotes would nest the
# two: "--skill "'demo'"", which a shell still expands. A name carrying
# "$(touch …)" would then run.
#
# So a template that puts a placeholder next to a quote character is
# refused by name. The refusal says which placeholder and why, because
# the template is the user's own text and the fix is theirs to make.
mkdir -p "$SCRATCH/quoted"
printf '    <command> add --skill "<name>"\n' > "$SCRATCH/quoted/usage-log.md"
run skills template show --template-dir "$SCRATCH/quoted"
check "a template with a quoted placeholder is refused" "$STATUS" "1"
check_contains "the refusal names the quoted placeholder" "$ERR" \
    "usage-log.md"
check_contains "the refusal says a placeholder may not be quoted" "$ERR" \
    "quote"
check_one_line "the refusal for a quoted placeholder is one line" "$ERR"

# The same for the review template.
mkdir -p "$SCRATCH/quoted-review"
printf 'review with <command>\n' > "$SCRATCH/quoted-review/skill-friction-review.md"
printf "    <command> add --skill '<name>'\n" > "$SCRATCH/quoted-review/usage-log.md"
run skills template show --template-dir "$SCRATCH/quoted-review"
check "a template with a single-quoted placeholder is refused" "$STATUS" "1"
check_contains "the refusal names the single-quoted placeholder" "$ERR" \
    "usage-log.md"
check_contains "the refusal says a placeholder may not be quoted" "$ERR" \
    "quote"

# And the hostile name must not run through either path: the default
# template (which quotes the value itself) and the quoted override (which
# is refused before it renders).
# The command substitution is literal on purpose: it is the payload the
# case is about.
# shellcheck disable=SC2016  # the substitution is the payload, not a command
HOSTILE_NAME='$(touch '"$SCRATCH"'/quoted-pwned)'

# The default template: the value is quoted by the tool, so the name is
# a word and not a command.
rm -rf "$SCRATCH/hostile-quoted"
mkdir -p "$SCRATCH/hostile-quoted/evil"
printf -- '---\nname: %s\n---\n' "$HOSTILE_NAME" \
    > "$SCRATCH/hostile-quoted/evil/SKILL.md"
rm -f "$SCRATCH/quoted-pwned"
run skills adopt --dir "$SCRATCH/hostile-quoted"
check "the hostile name adopts through the default template" "$STATUS" "0"
HOSTILE_CMD="$(grep -m1 -- '--skill' "$SCRATCH/hostile-quoted/evil/SKILL.md" \
    | sed 's/^[[:space:]]*//')"
if [ -n "$HOSTILE_CMD" ]; then
    sh "$SCRATCH/hostile.cmd" >/dev/null 2>&1 || true
    printf '%s\n' "$HOSTILE_CMD" > "$SCRATCH/hostile-quoted.cmd"
    sh "$SCRATCH/hostile-quoted.cmd" >/dev/null 2>&1 || true
fi
if [ -e "$SCRATCH/quoted-pwned" ]; then
    fail "the default template ran the injected command"
else
    pass "the default template did not run the injected command"
fi

# The quoted override: refused before it renders, so nothing is written
# and nothing can run.
rm -rf "$SCRATCH/hostile-override"
mkdir -p "$SCRATCH/hostile-override/evil"
printf -- '---\nname: %s\n---\n' "$HOSTILE_NAME" \
    > "$SCRATCH/hostile-override/evil/SKILL.md"
rm -f "$SCRATCH/quoted-pwned"
run skills adopt --dir "$SCRATCH/hostile-override" \
    --template-dir "$SCRATCH/quoted"
check "the quoted override refuses the hostile name" "$STATUS" "1"
check_absent "the quoted override wrote no block" \
    "$(cat "$SCRATCH/hostile-override/evil/SKILL.md")" "skill-log:usage-log"
if [ -e "$SCRATCH/quoted-pwned" ]; then
    fail "the quoted override ran the injected command"
else
    pass "the quoted override did not run the injected command"
fi

# The resolved binary the block names: the tool resolves its own path,
# so the suite computes the same answer independently. The current
# render embeds it, so the fixtures need it too.
EXPECTED_CMD="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BIN")"

# ------------------------------------------------------- the fixtures

# Build the five state fixtures. The current render is what `ok` matches:
# the shipped usage-log template rendered for that skill's own name and
# the resolved binary path. The stale block is an older render of the
# same template (older wording). The edited block is a current render
# with its content changed after the fence hash was written. The
# vendored skill carries the vendor stamp.
SKILLS="$SCRATCH/skills"
rm -rf "$SKILLS"
for s in ok missing stale edited vendored; do
    mkdir -p "$SKILLS/$s"
    printf 'name: %s\n' "$s" > "$SKILLS/$s/SKILL.md"
done

# The current render, through the CLI's own template. The audit renders
# with name "skill" and command "skill-log"; a block built the same way is
# `ok`. The suite reads the template source from `skills template show
# --json` and replicates the render (same substitution, same FNV-1a hash)
# to build a fixture without hardcoding a hash.
TEMPLATE_JSON="$("$BIN" skills template show --json)"
USAGE_TEMPLATE="$(printf '%s' "$TEMPLATE_JSON" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["templates"][0]["content"])')"

# Render a block the way the audit does: substitute <name> and
# <command>, then compute the fence the CLI writes. The suite
# replicates the render to build a fixture without hardcoding a hash —
# the hash comes from the same bytes the CLI hashes.
# The template is passed as argv[3] because the heredoc owns stdin.
render_block() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
name, command, template = sys.argv[1], sys.argv[2], sys.argv[3]


def shell_quote(value):
    # The one way a POSIX shell reads a word back literally: single
    # quotes, with an embedded quote closed, escaped and reopened.
    return "'" + value.replace("'", "'\\''") + "'"


def is_command_line(line):
    """The line starts a command: the placeholder is the first thing on
    the line, or it follows a markdown list item's label and colon."""
    text = line.strip()
    if not text:
        return False
    if text.startswith("<name>") or text.startswith("<command>"):
        return True
    if not (text.startswith("- ") or text.startswith("* ") or text.startswith("+ ")):
        return False
    colon = text.find(":")
    if colon < 0:
        return False
    rest = text[colon + 1:].strip()
    return rest.startswith("<name>") or rest.startswith("<command>")


def substitute_line(line, name, command):
    """One line of the template, with the placeholders replaced.

    The placeholders are found and replaced in one pass, so a value is
    never read again: a skill name carrying a literal `<command>` token
    stays as it is. The tool substitutes the same way."""
    quoted = is_command_line(line)
    out = []
    at = 0
    while at < len(line):
        open_at = line.find("<", at)
        if open_at < 0:
            out.append(line[at:])
            break
        close_at = line.find(">", open_at)
        if close_at < 0:
            out.append(line[at:])
            break
        tag = line[open_at:close_at + 1]
        if tag == "<name>":
            value = name
        elif tag == "<command>":
            value = command
        else:
            # An unknown placeholder is left alone: the template's own
            # text is the user's, and the tool does not rewrite it.
            out.append(line[at:open_at + 1])
            at = open_at + 1
            continue
        out.append(line[at:open_at])
        out.append(shell_quote(value) if quoted else value)
        at = close_at + 1
    return "".join(out)


def substitute(text, name, command):
    return "\n".join(
        substitute_line(line, name, command) for line in text.split("\n")
    )


content = substitute(template, name, command)


def fnv1a64(s):
    h = 0xcbf29ce484222325
    for b in s.encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


th = fnv1a64(template)
ch = fnv1a64(content)
print("<!-- skill-log:usage-log template=%s hash=%s -->" % (th, ch))
print(content)
print("<!-- /skill-log:usage-log -->")
PY
}

render_block ok "$EXPECTED_CMD" "$USAGE_TEMPLATE" > "$SCRATCH/block.txt"
cat "$SCRATCH/block.txt" >> "$SKILLS/ok/SKILL.md"

# --------------------------------------------- the mirror is the oracle
#
# The fixtures above are built by the suite's own render, and the audit
# compares the tool's render against them byte for byte. So the mirror
# has to be the tool's render, not a lookalike: if the two disagree,
# the comparison can agree with a wrong answer.
#
# The one way they used to disagree: the mirror substituted `<name>` and
# then `<command>`, in two passes. A name carrying a literal `<command>`
# token therefore had the second pass run over the first pass's result.
# The tool substitutes in one pass, so a value is never re-read.
#
# The case: a skill whose name carries the token. The tool's own render
# and the mirror's must be the same bytes.
TOKEN_NAME='skill<command>evil'
TOKEN_DIR="$SCRATCH/token-name"
rm -rf "$TOKEN_DIR"
mkdir -p "$TOKEN_DIR/evil"
printf -- '---\nname: %s\n---\n' "$TOKEN_NAME" > "$TOKEN_DIR/evil/SKILL.md"
run skills adopt --dir "$TOKEN_DIR"
check "the token-name skill adopts" "$STATUS" "0"
TOKEN_BLOCK="$(cat "$TOKEN_DIR/evil/SKILL.md")"
# The tool left the token in the name: it substituted once.
check_contains "the tool does not re-substitute a value" "$TOKEN_BLOCK" \
    "'$TOKEN_NAME'"
check_absent "the tool did not substitute the token inside the value" \
    "$TOKEN_BLOCK" "'skill$EXPECTED_CMD"
# And the mirror agrees with it: the same render, byte for byte.
TOKEN_MIRROR="$(render_block "$TOKEN_NAME" "$EXPECTED_CMD" "$USAGE_TEMPLATE" \
    | sed 's/^<!--.*-->$/<!-- fence -->/')"
TOKEN_TOOL="$(printf '%s\n' "$TOKEN_BLOCK" \
    | sed -n '/^<!-- skill-log:usage-log/,/^<!-- \/skill-log:usage-log -->/p' \
    | sed 's/^<!--.*-->$/<!-- fence -->/')"
check "the mirror renders what the tool renders" \
    "$TOKEN_MIRROR" "$TOKEN_TOOL"

# stale: an older render — a different template's block.
render_block ok "$EXPECTED_CMD" '## Usage log

old wording
' > "$SCRATCH/block_stale.txt"
cat "$SCRATCH/block_stale.txt" >> "$SKILLS/stale/SKILL.md"

# edited: a current render whose content was changed after the fence.
cat "$SCRATCH/block.txt" >> "$SKILLS/edited/SKILL.md"
sed -i 's/silent write/quiet write/' "$SKILLS/edited/SKILL.md"

# vendored: the vendor stamp plus a block (which must be skipped entirely).
{
    printf -- '---\n'
    printf 'name: vendored\n'
    printf 'metadata:\n'
    printf '  source: https://example.com/upstream\n'
    printf -- '---\n'
} > "$SKILLS/vendored/SKILL.md"
cat "$SCRATCH/block_stale.txt" >> "$SKILLS/vendored/SKILL.md"

# missing, with stale unfenced usage-log text nearby — which the tool must
# never read or touch. `missing` is the state even though the text is
# there, and the text survives the audit untouched.
UNFENCED='## Usage log

this is old unfenced usage-log text that must never be matched or rewritten'
printf '%s\n' "$UNFENCED" >> "$SKILLS/missing/SKILL.md"
BEFORE_MISSING="$(md5sum < "$SKILLS/missing/SKILL.md")"

# ------------------------------------------------------------- audit

run skills audit --dir "$SKILLS"
check "audit exits 1 on a dirty directory" "$STATUS" "1"
check "audit reports five states" \
    "$(printf '%s\n' "$OUT" | grep -c 'ok\|missing\|stale\|edited\|vendored')" "5"
check "audit reports ok" \
    "$(printf '%s\n' "$OUT" | grep -c '^ok  ok')" "1"
check "audit reports missing" \
    "$(printf '%s\n' "$OUT" | grep -c '^missing  missing')" "1"
check "audit reports stale" \
    "$(printf '%s\n' "$OUT" | grep -c '^stale  stale')" "1"
check "audit reports edited" \
    "$(printf '%s\n' "$OUT" | grep -c '^edited  edited')" "1"
check "audit reports vendored" \
    "$(printf '%s\n' "$OUT" | grep -c '^vendored  vendored')" "1"

check "the missing skill's unfenced text is untouched" \
    "$(md5sum < "$SKILLS/missing/SKILL.md")" "$BEFORE_MISSING"

run skills audit --dir "$SKILLS" --json
check "audit --json exits 1 on a dirty directory" "$STATUS" "1"
check "audit --json emits one object per skill" \
    "$(printf '%s\n' "$OUT" | grep -c '^{')" "5"
check "audit --json object keys are exactly skill, path, state" \
    "$(printf '%s\n' "$OUT" | head -1 | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')" \
    "path skill state"
check "audit --json classifies all five states" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; s={json.loads(l)["state"] for l in sys.stdin if l.strip()}; print(" ".join(sorted(s)))')" \
    "edited missing ok stale vendored"

# A clean directory (only ok and vendored) exits 0.
CLEAN="$SCRATCH/clean"
rm -rf "$CLEAN"
mkdir -p "$CLEAN/ok" "$CLEAN/vendored"
render_block ok "$EXPECTED_CMD" "$USAGE_TEMPLATE" > "$SCRATCH/block_clean.txt"
cat "$SCRATCH/block_clean.txt" >> "$CLEAN/ok/SKILL.md"
{
    printf -- '---\nname: vendored\nmetadata:\n  source: https://example.com\n---\n'
} > "$CLEAN/vendored/SKILL.md"
cat "$SCRATCH/block_stale.txt" >> "$CLEAN/vendored/SKILL.md"
printf 'name: ok\n' > "$CLEAN/ok/SKILL.md.bak"

run skills audit --dir "$CLEAN"
check "a clean directory exits 0" "$STATUS" "0"

# An empty directory (no SKILL.md subdirectories) is refused.
EMPTY="$SCRATCH/empty"
rm -rf "$EMPTY"
mkdir -p "$EMPTY"
run skills audit --dir "$EMPTY"
check "an empty directory is refused" "$STATUS" "1"
check "the refusal names the directory" "$ERR" \
    "skill-log: no skills in $EMPTY (no subdirectory holds a SKILL.md)"

# The audit writes nothing: no state directory, no store, nothing in the
# skills dir. The state dir is removed first so its absence is meaningful.
rm -rf "$XDG_STATE_HOME"
AFTER_BEFORE="$(md5sum < "$SKILLS/edited/SKILL.md")"
run skills audit --dir "$SKILLS" --json >/dev/null 2>&1
run skills audit --dir "$SKILLS" >/dev/null 2>&1
check "the audit does not create a state directory" \
    "$(test -e "$XDG_STATE_HOME" && echo yes || echo no)" "no"
check "the audit does not change a skill file" \
    "$(md5sum < "$SKILLS/edited/SKILL.md")" "$AFTER_BEFORE"

# --dry-run is accepted and changes nothing.
run skills audit --dir "$SKILLS" --dry-run
check "audit --dry-run is accepted" "$STATUS" "1"
check "the audit still writes nothing with --dry-run" \
    "$(test -e "$XDG_STATE_HOME" && echo yes || echo no)" "no"

# ------------------------------------------------------------- adopt

# adopt writes: it appends a block where there is none, rewrites a stale
# one, rewrites an edited one only with --force, skips vendored skills
# and leaves an ok one alone. The five fixtures from the audit section
# are still pristine (the audit is read-only); their originals are kept
# so byte-exactness can be proved by removing the fence block again.
cp -r "$SKILLS" "$SCRATCH/skills.orig"

# strip_block <file>: the file with its fenced usage-log block removed —
# every byte outside the fence, in order. Comparing it with the
# pre-adopt original is the byte-exactness proof: nothing outside the
# fence changed.
strip_block() {
    python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").readlines()
out, inside = [], False
for line in lines:
    if line.startswith("<!-- skill-log:usage-log"):
        inside = True
        continue
    if inside:
        if line.startswith("<!-- /skill-log:usage-log -->"):
            inside = False
        continue
    out.append(line)
sys.stdout.write("".join(out))
PY
}

# adopt's dry run previews every action and writes nothing.
run skills adopt --dir "$SKILLS" --json --dry-run
check "adopt --dry-run exits 1 when a skill would be refused" "$STATUS" "1"
check "adopt --dry-run emits one object per skill" \
    "$(printf '%s\n' "$OUT" | grep -c '^{')" "5"
check "adopt --json object keys are exactly skill, path, state, action" \
    "$(printf '%s\n' "$OUT" | head -1 | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')" \
    "action path skill state"
check "adopt --json classifies all five states" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; s={json.loads(l)["state"] for l in sys.stdin if l.strip()}; print(" ".join(sorted(s)))')" \
    "edited missing ok stale vendored"
check "adopt --dry-run previews all five actions" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; s={json.loads(l)["action"] for l in sys.stdin if l.strip()}; print(" ".join(sorted(s)))')" \
    "appended refused rewritten skipped unchanged"
check "adopt --dry-run writes nothing" \
    "$(diff -r "$SCRATCH/skills.orig" "$SKILLS" >/dev/null 2>&1 && echo same || echo differ)" "same"

# The real run does what the dry run said and prints the same lines,
# and exits 1 because the edited block was refused without --force.
run skills adopt --dir "$SKILLS" --dry-run
DRY_TEXT="$OUT"
run skills adopt --dir "$SKILLS"
check "adopt without --force exits 1 on a refused skill" "$STATUS" "1"
check "adopt names the refusal on stderr" "$ERR" \
    "skill-log: some skills were refused (an edited block is rewritten only with --force)"
check "adopt prints what its dry run printed" "$OUT" "$DRY_TEXT"
check_contains "adopt reports the append" "$OUT" "appended  missing  missing  $SKILLS/missing"
check_contains "adopt reports the rewrite" "$OUT" "rewritten  stale  stale  $SKILLS/stale"
check_contains "adopt reports the refusal" "$OUT" "refused  edited  edited  $SKILLS/edited"
check_contains "adopt reports the skip" "$OUT" "skipped  vendored  vendored  $SKILLS/vendored"
check_contains "adopt reports the unchanged skill" "$OUT" "unchanged  ok  ok  $SKILLS/ok"

# missing: the block is appended at the end, rendered for the skill —
# <name> from its frontmatter (absent here: the directory name), and
# <command> the resolved binary path.
check "the missing skill got exactly one block appended" \
    "$(grep -c '^<!-- skill-log:usage-log' "$SKILLS/missing/SKILL.md")" "1"
check_contains "the appended block names the skill" \
    "$(cat "$SKILLS/missing/SKILL.md")" "add --skill 'missing'"
check_contains "the appended block names the resolved binary" \
    "$(cat "$SKILLS/missing/SKILL.md")" "'$EXPECTED_CMD' add --skill 'missing'"
{
    cat "$SCRATCH/skills.orig/missing/SKILL.md"
    render_block missing "$EXPECTED_CMD" "$USAGE_TEMPLATE"
} > "$SCRATCH/missing.expected"
check "the appended block is exactly the current render" \
    "$(md5sum < "$SKILLS/missing/SKILL.md")" \
    "$(md5sum < "$SCRATCH/missing.expected")"
check "the append changed no byte outside the fence" \
    "$(strip_block "$SKILLS/missing/SKILL.md" | md5sum)" \
    "$(md5sum < "$SCRATCH/skills.orig/missing/SKILL.md")"
check_contains "the unfenced usage-log text survives beyond the block" \
    "$(cat "$SKILLS/missing/SKILL.md")" "$UNFENCED"
check_absent "the unfenced text was not folded into the block" \
    "$(strip_block "$SKILLS/missing/SKILL.md")" "skill-log:usage-log"

# The rendered <name> is the skill's frontmatter name, not its
# directory name.
FRONT="$SCRATCH/front"
rm -rf "$FRONT"
mkdir -p "$FRONT/dirname"
printf -- '---\nname: frontname\ndescription: a fixture\n---\n\n# Fixture\n' \
    > "$FRONT/dirname/SKILL.md"
run skills adopt --dir "$FRONT"
check "adopt renders a skill with frontmatter" "$STATUS" "0"
check_contains "the block names the frontmatter name" \
    "$(cat "$FRONT/dirname/SKILL.md")" "add --skill 'frontname'"
check_absent "the block does not fall back to the directory name" \
    "$(cat "$FRONT/dirname/SKILL.md")" "add --skill dirname"

# stale: the block is rewritten inside its fence and the file is exactly
# the original outside of it. The expected file is the untouched prefix
# plus the render the current template produces for that skill.
{
    printf 'name: stale\n'
    render_block stale "$EXPECTED_CMD" "$USAGE_TEMPLATE"
} > "$SCRATCH/stale.expected"
check "the stale skill's block is exactly the current render" \
    "$(md5sum < "$SKILLS/stale/SKILL.md")" \
    "$(md5sum < "$SCRATCH/stale.expected")"
check "the rewrite changed no byte outside the fence" \
    "$(strip_block "$SKILLS/stale/SKILL.md" | md5sum)" \
    "$(strip_block "$SCRATCH/skills.orig/stale/SKILL.md" | md5sum)"
check_contains "the rewritten block carries the current render" \
    "$(cat "$SKILLS/stale/SKILL.md")" "add --skill 'stale'"

# edited: left untouched without --force, rewritten with it.
check "the edited skill is untouched without --force" \
    "$(md5sum < "$SKILLS/edited/SKILL.md")" \
    "$(md5sum < "$SCRATCH/skills.orig/edited/SKILL.md")"

# ok and vendored are never written, even under --force.
check "the ok skill is untouched" \
    "$(md5sum < "$SKILLS/ok/SKILL.md")" \
    "$(md5sum < "$SCRATCH/skills.orig/ok/SKILL.md")"
check "the vendored skill is untouched" \
    "$(md5sum < "$SKILLS/vendored/SKILL.md")" \
    "$(md5sum < "$SCRATCH/skills.orig/vendored/SKILL.md")"

run skills adopt --dir "$SKILLS" --force
check "adopt --force exits 0 when the directory ends conformant" "$STATUS" "0"
{
    printf 'name: edited\n'
    render_block edited "$EXPECTED_CMD" "$USAGE_TEMPLATE"
} > "$SCRATCH/edited.expected"
check "adopt --force rewrites the edited block" \
    "$(md5sum < "$SKILLS/edited/SKILL.md")" \
    "$(md5sum < "$SCRATCH/edited.expected")"
check "the forced rewrite changed no byte outside the fence" \
    "$(strip_block "$SKILLS/edited/SKILL.md" | md5sum)" \
    "$(strip_block "$SCRATCH/skills.orig/edited/SKILL.md" | md5sum)"
check "the vendored skill stays untouched under --force" \
    "$(md5sum < "$SKILLS/vendored/SKILL.md")" \
    "$(md5sum < "$SCRATCH/skills.orig/vendored/SKILL.md")"

# Idempotent: a second run changes nothing and every skill is
# unchanged or skipped.
cp -r "$SKILLS" "$SCRATCH/skills.adopted"
run skills adopt --dir "$SKILLS" --json
check "a second adopt exits 0" "$STATUS" "0"
check "a second adopt changes nothing" \
    "$(diff -r "$SCRATCH/skills.adopted" "$SKILLS" >/dev/null 2>&1 && echo same || echo differ)" "same"
check "a second adopt reports only unchanged and skipped" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; s={json.loads(l)["action"] for l in sys.stdin if l.strip()}; print(" ".join(sorted(s)))')" \
    "skipped unchanged"

# ------------------------------------------------ a moved binary is stale
#
# The block names the resolved binary path. When the binary moves, the
# current render names a different path, so the block is an older
# render: `stale`, and `adopt` rewrites it (SPEC §7: `ok` requires the
# content to match the current render).
MOVEDBIN="$SCRATCH/moved-bin"
rm -rf "$MOVEDBIN"
mkdir -p "$MOVEDBIN"
cp -r "$DIST/lib" "$MOVEDBIN/lib"
cp "$BIN" "$MOVEDBIN/skill-log"
chmod +x "$MOVEDBIN/skill-log"
MOVED_CMD="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$MOVEDBIN/skill-log")"

MOVE="$SCRATCH/moved-cmd"
rm -rf "$MOVE"
mkdir -p "$MOVE/beta"
printf 'name: beta\n' > "$MOVE/beta/SKILL.md"

# The block is written by the moved binary, so it names the moved path.
"$MOVEDBIN/skill-log" skills adopt --dir "$MOVE" >/dev/null
check "the moved binary writes the block" \
    "$(grep -c '^<!-- skill-log:usage-log' "$MOVE/beta/SKILL.md")" "1"
check_contains "the block names the moved binary" \
    "$(cat "$MOVE/beta/SKILL.md")" "$MOVED_CMD"

# The installed binary resolves to a different path, so the same block
# is an older render: stale, not ok.
run skills audit --dir "$MOVE" --json
check "audit exits 1 when the block names a moved binary" "$STATUS" "1"
check "the moved-binary block is stale" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')" \
    "stale"

run skills adopt --dir "$MOVE" --json
check "adopt rewrites the moved-binary block" "$STATUS" "0"
check "the rewrite reports the stale state" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); print(o["state"], o["action"])')" \
    "stale rewritten"
check_contains "the rewritten block names the installed binary" \
    "$(cat "$MOVE/beta/SKILL.md")" "$EXPECTED_CMD"
run skills audit --dir "$MOVE" --json
check "the rewritten block audits ok" "$STATUS" "0"
check "the rewritten block is ok" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')" \
    "ok"

# A renamed skill is stale too: the block names the skill it was
# rendered for.
RENAME="$SCRATCH/renamed"
rm -rf "$RENAME"
mkdir -p "$RENAME/before"
printf 'name: before\n' > "$RENAME/before/SKILL.md"
run skills adopt --dir "$RENAME"
check "the first adopt writes the block" "$STATUS" "0"
mv "$RENAME/before" "$RENAME/after"
run skills audit --dir "$RENAME" --json
check "a renamed skill audits stale" \
    "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')" \
    "stale"
run skills adopt --dir "$RENAME" --json
check "adopt rewrites the renamed skill's block" "$STATUS" "0"
check_contains "the rewritten block names the new skill" \
    "$(cat "$RENAME/after/SKILL.md")" "add --skill 'after'"


# A file with no trailing newline still gets its block on its own line;
# the original bytes survive as a prefix and the second run is a no-op.
NONL="$SCRATCH/nonl"
rm -rf "$NONL"
mkdir -p "$NONL/gamma"
printf 'name: gamma' > "$NONL/gamma/SKILL.md"
cp "$NONL/gamma/SKILL.md" "$SCRATCH/gamma.orig"
run skills adopt --dir "$NONL"
check "adopt appends to a file without a trailing newline" "$STATUS" "0"
check "the no-newline file kept its bytes as a prefix" \
    "$(head -c "$(wc -c < "$SCRATCH/gamma.orig")" "$NONL/gamma/SKILL.md" | md5sum)" \
    "$(md5sum < "$SCRATCH/gamma.orig")"
check "the no-newline file's block is on its own line" \
    "$(grep -c '^<!-- skill-log:usage-log' "$NONL/gamma/SKILL.md")" "1"
cp "$NONL/gamma/SKILL.md" "$SCRATCH/gamma.adopted"
run skills adopt --dir "$NONL"
check "the no-newline file is idempotent" \
    "$(diff "$SCRATCH/gamma.adopted" "$NONL/gamma/SKILL.md" >/dev/null 2>&1 && echo same || echo differ)" "same"

# An empty directory (no SKILL.md subdirectories) is refused, exactly as
# the audit refuses it.
run skills adopt --dir "$EMPTY"
check "adopt refuses an empty directory" "$STATUS" "1"
check "the refusal names the directory" "$ERR" \
    "skill-log: no skills in $EMPTY (no subdirectory holds a SKILL.md)"

# ------------------------------- a moved user template makes blocks stale

# The block was written from the shipped default; a user copy that
# differs is the current render, so the block is an older one — stale —
# and adopt rewrites it from the user copy.
run skills template seed
check "seed writes a user copy for the adopt fixtures" "$STATUS" "0"
MOVED="$SCRATCH/moved"
rm -rf "$MOVED"
mkdir -p "$MOVED/alpha"
printf 'name: alpha\n' > "$MOVED/alpha/SKILL.md"
run skills adopt --dir "$MOVED"
check "the first adopt writes the block" "$STATUS" "0"
cp "$MOVED/alpha/SKILL.md" "$SCRATCH/alpha.before"

printf '\nthe user added this line\n' >> "$TPL/usage-log.md"
run skills adopt --dir "$MOVED" --json
check "a moved template is adopted as a rewrite" "$STATUS" "0"
check "the rewrite reports the stale state" \
    "$(printf '%s\n' "$OUT" | head -1 | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); print(o["state"], o["action"])')" \
    "stale rewritten"
check_contains "the rewritten block carries the user's wording" \
    "$(cat "$MOVED/alpha/SKILL.md")" "the user added this line"
check "the rewrite changed no byte outside the fence" \
    "$(strip_block "$MOVED/alpha/SKILL.md" | md5sum)" \
    "$(strip_block "$SCRATCH/alpha.before" | md5sum)"
cp "$MOVED/alpha/SKILL.md" "$SCRATCH/alpha.adopted"
run skills adopt --dir "$MOVED" --json
check "the rewritten block is idempotent" \
    "$(diff "$SCRATCH/alpha.adopted" "$MOVED/alpha/SKILL.md" >/dev/null 2>&1 && echo same || echo differ)" "same"

# Back to the shipped defaults for whatever runs next.
run skills template reset --force
check "reset returns to the shipped defaults" "$STATUS" "0"

# ---------------------------------------------------- usage errors

run skills
check "skills with no subcommand is a usage error" "$STATUS" "2"
run skills adopt
check "adopt with no --dir is a usage error" "$STATUS" "2"
run skills adopt --dir
check "adopt --dir with no value is a usage error" "$STATUS" "2"
run skills audit
check "audit with no --dir is a usage error" "$STATUS" "2"
run skills audit --dir
check "audit --dir with no value is a usage error" "$STATUS" "2"
run skills template
check "template with no subcommand is a usage error" "$STATUS" "2"
run skills template nope
check "an unknown template subcommand is refused" "$STATUS" "2"
run skills --nope
check "an unknown skills flag is a usage error" "$STATUS" "2"

# ------------------------------------------------------------- report

tally
