#!/usr/bin/env bash
# The resolve test: the manual stamp, against the built artifact.
#
#   tests/resolve.sh
#
# It exercises the escape hatch: one row, one commit, one timestamp. The
# cases are the four promises — the stamp lands, the same call changes
# nothing, a dry run writes nothing, and an unknown id or a missing store
# is named.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-resolve-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a caller's
# SCRATCH is theirs to clean up.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools sqlite3 python3

if [ ! -x "$BIN" ]; then
    printf 'resolve.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home"

export HOME="$SCRATCH/home"
unset XDG_STATE_HOME SKILL_LOG_DB
unset SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME

DB="$HOME/.local/state/skill-log/skills.db"

# run <args...>: the binary with the sandbox's environment.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# ---------------------------------------------------------- named failures

run resolve --id 1 --fix abc1234
check "a missing store exits 1" "$STATUS" "1"
check "a missing store is named" "$ERR" \
    "skill-log: no store at $DB (add a row first)"
if [ -e "$DB" ]; then
    fail "resolve created a store"
else
    pass "resolve creates no store"
fi

run add --skill alpha --machine boxA
check "the first row is written" "$STATUS" "0"
run add --skill beta --machine boxA
check "the second row is written" "$STATUS" "0"

run resolve --id 99 --fix abc1234
check "an unknown id exits 1" "$STATUS" "1"
check "an unknown id is named" "$ERR" \
    "skill-log: no invocation 99 in $DB"
check_one_line "an unknown id is one line" "$ERR"

# ---------------------------------------------------------------- the stamp

run resolve --id 1 --fix abc1234
check "resolve exits 0" "$STATUS" "0"
check "resolve prints the marker and the commit" "$OUT" \
    "boxA#1 resolved: abc1234"
check "the fix lands" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 1')" "abc1234"
check "the timestamp is ISO 8601 with an offset" \
    "$(sqlite3 "$DB" "select resolved_at from invocations where id = 1" \
        | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"
check "the other row is untouched" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 2')" ""

FIRST_STAMP="$(sqlite3 "$DB" 'select resolved_at from invocations where id = 1')"
run resolve --id 1 --fix abc1234
check "a repeated resolve exits 0" "$STATUS" "0"
check "a repeated resolve says already resolved" "$OUT" \
    "boxA#1 already resolved: abc1234"
check "a repeated resolve keeps the first timestamp" \
    "$(sqlite3 "$DB" 'select resolved_at from invocations where id = 1')" \
    "$FIRST_STAMP"

run resolve --id 1 --fix def5678
check "a different commit resolves again" "$OUT" "boxA#1 resolved: def5678"
check "a different commit is written" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 1')" "def5678"

# ------------------------------------------------------------------ dry run

BEFORE_FIX="$(sqlite3 "$DB" 'select fix from invocations where id = 2')"
BEFORE_STAMP="$(sqlite3 "$DB" 'select resolved_at from invocations where id = 2')"
BEFORE_SUM="$(md5sum <"$DB")"
run resolve --id 2 --fix deadbeef --dry-run
check "a dry run exits 0" "$STATUS" "0"
check "a dry run says what it would stamp" "$OUT" \
    "boxA#2 would resolve: deadbeef"
check "a dry run leaves the fix alone" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 2')" "$BEFORE_FIX"
check "a dry run leaves the timestamp alone" \
    "$(sqlite3 "$DB" 'select resolved_at from invocations where id = 2')" \
    "$BEFORE_STAMP"
check "a dry run does not change the store file" \
    "$(md5sum <"$DB")" "$BEFORE_SUM"

run resolve --id 1 --fix def5678 --dry-run
check "a dry run of a repeat says already resolved" "$OUT" \
    "boxA#1 already resolved: def5678"

# ------------------------------------------------------------------- json

run resolve --id 2 --fix cafebabe --json
check "json exits 0" "$STATUS" "0"
check "json carries the row's facts" "$(json_keys "$OUT")" \
    "changed dry_run fix id marker resolved_at skill"
check "json carries the id" "$(json_field "$OUT" id)" "2"
check "json carries the marker" "$(json_field "$OUT" marker)" "boxA#2"
check "json carries the skill" "$(json_field "$OUT" skill)" "beta"
check "json carries the commit" "$(json_field "$OUT" fix)" "cafebabe"
check "json says it changed" "$(json_field "$OUT" changed)" "True"
check "json says it was not a dry run" "$(json_field "$OUT" dry_run)" "False"

run resolve --id 2 --fix cafebabe --json
check "json says a repeat changed nothing" "$(json_field "$OUT" changed)" "False"
run resolve --id 2 --fix 11112222 --dry-run --json
check "a dry-run json says so" "$(json_field "$OUT" dry_run)" "True"

# --------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
BEFORE_SUM="$(md5sum <"$SCRATCH/damaged.db")"
run resolve --id 1 --fix abc --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "a damaged store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "a damaged store is one line" "$ERR"
check "a damaged store is not written" \
    "$(md5sum <"$SCRATCH/damaged.db")" "$BEFORE_SUM"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
BEFORE_SUM="$(md5sum <"$SCRATCH/foreign.db")"
run resolve --id 1 --fix abc --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "a foreign store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'foreign store')" "1"
check "a foreign store is not written" \
    "$(md5sum <"$SCRATCH/foreign.db")" "$BEFORE_SUM"

sqlite3 "$DB" 'pragma wal_checkpoint(TRUNCATE)'
cp "$DB" "$SCRATCH/newer.db"
sqlite3 "$SCRATCH/newer.db" 'pragma user_version=99'
run resolve --id 1 --fix abc --db "$SCRATCH/newer.db"
check "a newer store exits 1" "$STATUS" "1"
check "a newer store is named with both versions" \
    "$(printf '%s\n' "$ERR" | grep -c 'has schema version 99.*understands 1')" "1"

# ----------------------------------------------------------- usage errors

run resolve
check "a missing --id and --fix exits 2" "$STATUS" "2"
check_one_line "a missing --id and --fix is one line" "$ERR"

run resolve --id 1
check "a missing --fix exits 2" "$STATUS" "2"
check_one_line "a missing --fix is one line" "$ERR"

run resolve --fix abc
check "a missing --id exits 2" "$STATUS" "2"
check_one_line "a missing --id is one line" "$ERR"

run resolve --id 0 --fix abc
check "--id 0 exits 2" "$STATUS" "2"
check_one_line "--id 0 is one line" "$ERR"

run resolve --id abc --fix abc
check "--id abc exits 2" "$STATUS" "2"
check_one_line "--id abc is one line" "$ERR"

run resolve --id 1 --fix "  "
check "an empty --fix exits 2" "$STATUS" "2"
check_one_line "an empty --fix is one line" "$ERR"

run resolve --id 1 --fix "$(printf 'a\nb')"
check "a multi-line --fix exits 2" "$STATUS" "2"
check_one_line "a multi-line --fix is one line" "$ERR"

run resolve --id 1 --fix abc --nope
check "an unknown flag exits 2" "$STATUS" "2"
check_one_line "an unknown flag is one line" "$ERR"

run resolve --id 1 --fix -h
check "a --fix value spelled -h is a value" "$STATUS" "0"
check "a --fix value spelled -h is written" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 1')" "-h"
run resolve --id 1 -h
check "a help flag after a value still asks for help" "$STATUS" "0"
check "the help block is the verb's usage" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"

: >"$SCRATCH/tableless.db"
run resolve --id 1 --fix abc --db "$SCRATCH/tableless.db"
check "a table-less store names the unknown id" "$STATUS" "1"
check "a table-less store does not fail on the missing tables" "$ERR" \
    "skill-log: no invocation 1 in $SCRATCH/tableless.db"

# ------------------------------------------------------------------ races
#
# Six identical resolves of one row run at once. The read that decides
# "already resolved" happens inside the write transaction, so exactly one
# of them stamps and the rest see that stamp.
run add --skill parallel --machine boxA
check "the race fixture row is written" "$STATUS" "0"
RACE_ID="$(sqlite3 "$DB" 'select max(id) from invocations')"
rm -f "$SCRATCH"/race-*.json "$SCRATCH"/race-*.err
for i in 1 2 3 4 5 6; do
    "$BIN" resolve --id "$RACE_ID" --fix r4cec0de --json \
        >"$SCRATCH/race-$i.json" 2>"$SCRATCH/race-$i.err" &
done
wait
check "every concurrent resolve succeeds" \
    "$(cat "$SCRATCH"/race-*.err | grep -c .)" "0"
check "exactly one concurrent resolve changed the row" \
    "$(cat "$SCRATCH"/race-*.json | grep -c '"changed":true')" "1"
check "concurrent resolves agree on one timestamp" \
    "$(cat "$SCRATCH"/race-*.json \
        | python3 -c 'import json,sys; print(len({json.loads(l)["resolved_at"] for l in sys.stdin if l.strip()}))')" \
    "1"

# ------------------------------------------------------------------ help

run resolve --help
check "resolve --help exits 0" "$STATUS" "0"
for flag in --id --fix --dry-run --json --db; do
    check_contains "resolve --help lists $flag" "$OUT" "$flag"
done
check "resolve --help ends with 2 to 4 real invocations" \
    "$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "3"
check_contains "resolve --help names the hook path" "$OUT" "post-merge hook"

# ----------------------------------------------------------------- report

tally
