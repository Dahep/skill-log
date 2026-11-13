#!/usr/bin/env bash
# The stats test: counts and the friction rate against the built artifact.
#
#   tests/stats.sh
#
# It exercises the read that answers "which skills need attention": the
# four distinct counts, the rate, every `--by` key, the `--skill` narrow,
# the flat JSON line, the empty answer, and the refusals. The fixture is
# built through `add` and `resolve` (the CLI is the only writer), with one
# row resolved by the CLI, and one worktree under
# the sandbox home so the shortening has something to shorten.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-stats-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a
# caller's SCRATCH is theirs to clean up. A fixed path would let two
# runs on one machine clobber each other's stores.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools sqlite3 python3

if [ ! -x "$BIN" ]; then
    printf 'stats.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home"

HOME_DIR="$SCRATCH/home"

# The sandbox's HOME, so nothing reaches the real store.
export HOME="$HOME_DIR"
unset XDG_STATE_HOME SKILL_LOG_DB
unset SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME

DB="$HOME_DIR/.local/state/skill-log/skills.db"

# run <args...>: the binary with the sandbox's environment. Output lands
# in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# ------------------------------------------------------------ absent store

run stats
check "an absent store exits 0" "$STATUS" "0"
check "an absent store says so" "$OUT" "no invocations logged yet"
if [ -e "$HOME_DIR/.local/state" ]; then
    fail "stats created the state directory"
else
    pass "stats creates no state directory"
fi

"$BIN" stats --json >"$SCRATCH/absent.json" 2>"$SCRATCH/stderr"
check "an absent store in json exits 0" "$?" "0"
check "an absent store in json prints nothing" \
    "$(wc -c <"$SCRATCH/absent.json" | tr -d ' ')" "0"

run stats --db "$SCRATCH/fresh/state/skill-log/skills.db"
check "a fresh --db path exits 0" "$STATUS" "0"
if [ -e "$SCRATCH/fresh" ]; then
    fail "stats created a store directory"
else
    pass "stats creates no store directory"
fi

# ------------------------------------------------------------------- rows
#
# Three skills over two harnesses, two models, two repos, two machines and
# three projects, with the problem counts chosen so every total is
# distinguishable from every other one:
#
#   alpha  two runs: two problems then one; the second run is resolved
#   beta   one clean run
#   gamma  one run with one problem, under the home directory

# The rows are written from outside the repository: a row added inside a
# checkout would carry its worktree, and the empty-key case below needs
# runs that have none.
cd "$SCRATCH" || exit 1

run add --skill alpha --machine boxA --harness opencode --model m1 \
    --repo r1 --project pA --problem "one" --problem "two"
check "the first row is written" "$STATUS" "0"

run add --skill alpha --machine boxA --harness claude --model m1 \
    --repo r2 --project pB --problem "three"
check "the second row is written" "$STATUS" "0"

run add --skill beta --machine boxB --harness opencode --model m2 --repo r1
check "the third row is written" "$STATUS" "0"

run add --skill gamma --machine boxA --harness claude --model m2 \
    --repo r2 --worktree "$HOME_DIR/wt" --problem "four"
check "the fourth row is written" "$STATUS" "0"

# The row a change resolved: the CLI resolves it, the way a real change
# does.
ALPHA_TWO_ID="$(sqlite3 "$DB" \
    "select id from invocations where skill = 'alpha' and repo = 'r2'")"
run resolve --id "$ALPHA_TWO_ID" --fix abc1234 --db "$DB"
check "the alpha row is resolved" "$STATUS" "0"

# ------------------------------------------------------------------ table

run stats
check "stats exits 0" "$STATUS" "0"
TABLE="$OUT"
for column in skill invocations with_problems problems resolved \
    problems/invocation; do
    check_contains "the table header lists $column" "$TABLE" "$column"
done
check "the default cut is skill" \
    "$(printf '%s\n' "$TABLE" | grep -c '^alpha')" "1"
check "the alpha counts are distinct" \
    "$(printf '%s\n' "$TABLE" | grep -cE '^alpha +2 +2 +3 +1 +1[.]50$')" "1"
check "a clean skill has a zero rate" \
    "$(printf '%s\n' "$TABLE" | grep -cE '^beta +1 +0 +0 +0 +0[.]00$')" "1"
check "a resolved count is per invocation" \
    "$(printf '%s\n' "$TABLE" | grep -cE '^gamma +1 +1 +1 +0 +1[.]00$')" "1"

# ------------------------------------------------------------------- json

run stats --json
check "json exits 0" "$STATUS" "0"
check "json is one object per group" "$(printf '%s\n' "$OUT" | grep -c .)" "3"
ALPHA_JSON="$(printf '%s\n' "$OUT" | grep '"skill":"alpha"')"
check "json carries the grouping column" "$(json_field "$ALPHA_JSON" skill)" \
    "alpha"
check "json carries every table column" "$(json_keys "$ALPHA_JSON")" \
    "invocations problems problems_per_invocation resolved skill with_problems"
check "json carries the invocation count" \
    "$(json_field "$ALPHA_JSON" invocations)" "2"
check "json carries the with-problems count" \
    "$(json_field "$ALPHA_JSON" with_problems)" "2"
check "json carries the problem count" \
    "$(json_field "$ALPHA_JSON" problems)" "3"
check "json carries the resolved count" \
    "$(json_field "$ALPHA_JSON" resolved)" "1"
check "json carries the rate as a number" \
    "$(json_number "$ALPHA_JSON" problems_per_invocation)" "1.5"
check "json carries no trailing blank line" \
    "$(printf '%s\n' "$OUT" | grep -c '^$')" "0"

# ------------------------------------------------------------------- cuts

# Every valid key is accepted, appears as the grouping column, and keeps
# the counts it groups.
run stats --by harness --json
check "the harness cut names its column" \
    "$(json_field "$(printf '%s\n' "$OUT" | head -n1)" harness)" "claude"
CLAUDE="$(printf '%s\n' "$OUT" | grep '"harness":"claude"')"
check "the claude cut counts both harnesses' runs" \
    "$(json_field "$CLAUDE" invocations)" "2"
check "the claude cut counts the resolved run" \
    "$(json_field "$CLAUDE" resolved)" "1"

run stats --by model --json
M1="$(printf '%s\n' "$OUT" | grep '"model":"m1"')"
check "the model cut groups the two m1 runs" \
    "$(json_field "$M1" invocations)" "2"
check "the model cut keeps the problems" "$(json_field "$M1" problems)" "3"
M2="$(printf '%s\n' "$OUT" | grep '"model":"m2"')"
check "the model cut's second group" "$(json_field "$M2" invocations)" "2"
check "the model cut's second group rate" \
    "$(json_number "$M2" problems_per_invocation)" "0.5"

run stats --by repo --json
R1="$(printf '%s\n' "$OUT" | grep '"repo":"r1"')"
check "the repo cut counts its runs" "$(json_field "$R1" invocations)" "2"
check "the repo cut counts its problems" "$(json_field "$R1" problems)" "2"

run stats --by machine --json
BOXA="$(printf '%s\n' "$OUT" | grep '"machine":"boxA"')"
check "the machine cut counts its runs" "$(json_field "$BOXA" invocations)" "3"
check "the machine cut rounds the rate" \
    "$(json_number "$BOXA" problems_per_invocation)" "1.33"

run stats --by project --json
PA="$(printf '%s\n' "$OUT" | grep '"project":"pA"')"
check "the project cut counts its runs" "$(json_field "$PA" invocations)" "1"
check "the project cut keeps its problems" "$(json_field "$PA" problems)" "2"
check "the empty project groups the run without one" \
    "$(printf '%s\n' "$OUT" | grep -c '"project":""')" "1"

# The worktree cut prints a shortened path in the table, while the JSON
# keeps the path whole; the empty key keeps its column empty rather than
# shifting the row left.
run stats --by worktree --json
check "the worktree cut keeps the path whole in json" \
    "$(printf '%s\n' "$OUT" | grep -c "\"worktree\":\"$HOME_DIR/wt\"")" "1"
run stats --by worktree
# The tilde is the literal output, not a path to expand.
# shellcheck disable=SC2088
check "the worktree table shortens the path" \
    "$(printf '%s\n' "$OUT" | grep -c '~/wt')" "1"
check "an empty grouping key keeps its column empty" \
    "$(printf '%s\n' "$OUT" | grep -cE '^ +3 +2 +3 +1 +1[.]00$')" "1"

# --by-model is kept as the rotation alias.
run stats --by model --json
BY_MODEL="$OUT"
run stats --by-model --json
check "--by-model is the model cut" "$OUT" "$BY_MODEL"

# ---------------------------------------------------------------- narrowing

run stats --skill alpha --json
check "--skill narrows the cut" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check "--skill keeps the skill's counts" \
    "$(printf '%s\n' "$OUT" | grep -c '"skill":"alpha"')" "1"

run stats --skill alpha --by model --json
check "--skill and --by compose" \
    "$(printf '%s\n' "$OUT" | grep -c '"model":"m1"')" "1"

run stats --skill nosuch
check "a skill with no rows exits 0" "$STATUS" "0"
check "a skill with no rows says which skill" "$OUT" \
    "no invocations match --skill nosuch"
run stats --skill nosuch --json
check "a skill with no rows has an empty JSON stream" "$OUT" ""

# ------------------------------------------------------------ empty store

# A store of this schema with no rows is the same answer as an absent one.
run add --skill gone --db "$SCRATCH/blank.db"
sqlite3 "$SCRATCH/blank.db" 'delete from problems; delete from invocations'
run stats --db "$SCRATCH/blank.db"
check "a store with no rows exits 0" "$STATUS" "0"
check "a store with no rows says so" "$OUT" "no invocations logged yet"
"$BIN" stats --db "$SCRATCH/blank.db" --json \
    >"$SCRATCH/blank.json" 2>/dev/null
check "a store with no rows has an empty JSON stream" \
    "$(wc -c <"$SCRATCH/blank.json" | tr -d ' ')" "0"

# --------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
DAMAGED_SUM="$(md5sum <"$SCRATCH/damaged.db")"
run stats --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "stats names a damaged store" \
    "$(printf '%s\n' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "a damaged store is one line" "$ERR"
check "a damaged store is not written" \
    "$(md5sum <"$SCRATCH/damaged.db")" "$DAMAGED_SUM"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
FOREIGN_SUM="$(md5sum <"$SCRATCH/foreign.db")"
run stats --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "stats names a foreign store" \
    "$(printf '%s\n' "$ERR" | grep -c 'foreign store')" "1"
check_one_line "a foreign store is one line" "$ERR"
check "a foreign store is not converted" \
    "$(md5sum <"$SCRATCH/foreign.db")" "$FOREIGN_SUM"

sqlite3 "$DB" 'pragma wal_checkpoint(TRUNCATE)'
cp "$DB" "$SCRATCH/newer.db"
sqlite3 "$SCRATCH/newer.db" 'pragma user_version=99'
run stats --db "$SCRATCH/newer.db"
check "a newer store exits 1" "$STATUS" "1"
check "stats names a newer store with both versions" \
    "$(printf '%s\n' "$ERR" | grep -c 'has schema version 99.*understands 1')" "1"

# ------------------------------------------------------- reads never write

STATE_DIR="$HOME_DIR/.local/state/skill-log"
# A reader may leave SQLite's own -wal/-shm sidecars behind (it needs
# them to read a WAL store); the store file itself is the invariant, and
# it is asserted byte-identical above.
files_besides_sidecars() {
    find "$STATE_DIR" -maxdepth 1 -mindepth 1 -printf '%f\n' \
        | grep -vE '^skills[.]db-(wal|shm)$' | sort | tr '\n' ' ' || true
}
BEFORE_FILES="$(files_besides_sidecars)"

BEFORE_SUM="$(md5sum <"$DB")"
BEFORE_MTIME="$(stat -c %Y "$DB")"

run stats
run stats --json
run stats --by harness
run stats --skill alpha --by model

check "the store is byte-identical after a read" \
    "$(md5sum <"$DB")" "$BEFORE_SUM"
check "the store's mtime is unchanged after a read" \
    "$(stat -c %Y "$DB")" "$BEFORE_MTIME"
check "a read creates no new file of its own" \
    "$(files_besides_sidecars)" "$BEFORE_FILES"

# ----------------------------------------------------------- usage errors

run stats --by nope
check "an unknown --by key exits 2" "$STATUS" "2"
check_one_line "an unknown --by key is one line" "$ERR"
for key in skill harness model repo worktree machine project; do
    check_contains "an unknown --by key lists $key" "$ERR" "$key"
done
check "an unknown --by key keeps stdout empty" "$OUT" ""

run stats --by ""
check "an empty --by key exits 2" "$STATUS" "2"
check_one_line "an empty --by key is one line" "$ERR"

run stats --by
check "a missing --by value exits 2" "$STATUS" "2"
check_one_line "a missing --by value is one line" "$ERR"

run stats --skill
check "a missing --skill value exits 2" "$STATUS" "2"
check_one_line "a missing --skill value is one line" "$ERR"

run stats --skill ""
check "an empty --skill value exits 2" "$STATUS" "2"
check_one_line "an empty --skill value is one line" "$ERR"

run stats --nope
check "an unknown flag exits 2" "$STATUS" "2"
check_one_line "an unknown flag is one line" "$ERR"

# A flag's value is taken as written: `--by -h` is the column `-h`, and a
# help flag elsewhere is still a help request.
run stats --by -h
check "a --by value spelled -h is a value" "$STATUS" "2"
check_contains "a --by value spelled -h is not a help request" "$ERR" \
    "--by takes one of"
run stats --skill alpha -h
check "a help flag after a value still asks for help" "$STATUS" "0"
check "the help block is the verb's usage" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"

# ------------------------------------------------------------------ help

run stats --help
check "stats --help exits 0" "$STATUS" "0"
for flag in --by --skill --json --db; do
    check_contains "stats --help lists $flag" "$OUT" "$flag"
done
for key in skill harness model repo worktree machine project; do
    check_contains "stats --help lists the $key cut" "$OUT" "$key"
done
check "stats --help ends with 2 to 4 real invocations" \
    "$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "4"
check_contains "stats --help keeps the read-only note" "$OUT" "never writes"

# ----------------------------------------------------------------- report

tally
