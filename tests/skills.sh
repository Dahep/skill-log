#!/usr/bin/env bash
# The skills test: templates, audit, and the document states, against the
# built artifact.
#
#   tests/skills.sh
#
# It exercises ticket #17's surface: the two shipped templates, their
# resolution chain and placeholder validation, `skills template
# show|seed|reset`, and `skills audit` over the five document states. The
# cases are the promises the spec makes — all five states classify, a
# `missing` skill with stale unfenced text nearby leaves that text
# untouched, a moved shipped default is reported with the two adopting
# commands and never applied, seed/reset refuse without `--force` and
# honour `--dry-run`, an empty directory is refused, the audit writes
# nothing, and every help block ends with real invocations.
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

# --------------------------------------------------------------- help

run skills --help
check "skills --help exits 0" "$STATUS" "0"
check "skills --help is the verb block" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"
EXAMPLES="$(count_examples "$OUT")"
if [ "$EXAMPLES" -ge 2 ] && [ "$EXAMPLES" -le 4 ]; then
    pass "skills --help ends with 2 to 4 real invocations"
else
    fail "skills --help ends with 2 to 4 real invocations (got $EXAMPLES)"
fi

for sub in "audit" "template show" "template seed" "template reset"; do
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

# ------------------------------------------------------- the fixtures

# Build the five state fixtures. The current render is what `ok` matches:
# a block rendered from the shipped usage-log template. The stale block is
# an older render (different template bytes). The edited block is a
# current render with its content changed after the fence hash was
# written. The vendored skill carries the vendor stamp.
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

# Render the current block the way the audit does: substitute <name> ->
# "skill" and <command> -> "skill-log", then compute the fence the CLI
# writes. The suite replicates the render to build a fixture without
# hardcoding a hash — the hash comes from the same bytes the CLI hashes.
# The template is passed as argv[3] because the heredoc owns stdin.
render_block() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
name, command, template = sys.argv[1], sys.argv[2], sys.argv[3]
content = template.replace("<name>", name).replace("<command>", command)
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

render_block skill skill-log "$USAGE_TEMPLATE" > "$SCRATCH/block.txt"
cat "$SCRATCH/block.txt" >> "$SKILLS/ok/SKILL.md"

# stale: an older render — a different template's block.
render_block skill skill-log '## Usage log

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
cat "$SCRATCH/block.txt" >> "$CLEAN/ok/SKILL.md"
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

# ---------------------------------------------------- usage errors

run skills
check "skills with no subcommand is a usage error" "$STATUS" "2"
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
