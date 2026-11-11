#!/usr/bin/env bash
# The store test: `add` against the built artifact, in a sandboxed home.
#
#   tests/store.sh
#
# It exercises the seam the contract is written against — the installed
# binary as a process — with a temporary HOME, a temporary XDG state
# directory, and no real store anywhere near it. The store file itself is
# inspected with the sqlite3 CLI where a case needs to see what was
# written; the CLI is the only writer.
#
# Cases: first-write creation, the row and its problems, blank problems,
# control characters, the deliberate non-idempotency, the marker shape,
# --dry-run writing nothing, --json, the three refusals, a failed write
# leaving nothing behind, path precedence, and usage errors.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-store}"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$1"
}

check() {
    # check <name> <actual> <expected>
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

if [ ! -x "$BIN" ]; then
    printf 'store.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home"

HOME_DIR="$SCRATCH/home"

# run <args...>: the binary with no inherited store configuration. Output
# lands in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$(env -u XDG_STATE_HOME -u SKILL_LOG_DB \
        HOME="$HOME_DIR" "$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

err_lines() {
    # A failure is exactly one line on stderr.
    printf '%s\n' "$ERR" | grep -c . || true
}

DB="$SCRATCH/home/.local/state/skill-log/skills.db"

# ---------------------------------------------------------------- creation

run add --skill demo
check "add exits 0" "$STATUS" "0"
check "add prints the marker" "$OUT" "$(hostname)#1"
if [ -f "$DB" ]; then pass "the first write created the state directory and the file"; else
    fail "the first write did not create the store"
fi
check "the store is WAL" "$(sqlite3 "$DB" 'pragma journal_mode')" "wal"
check "the schema version is stamped" "$(sqlite3 "$DB" 'pragma user_version')" "1"
check "one invocation row" "$(sqlite3 "$DB" 'select count(*) from invocations')" "1"

# ------------------------------------------------------------------- rows

run add --skill demo --problem "first issue" --problem "  " --problem "second issue"
check "a write with problems exits 0" "$STATUS" "0"
ID="$(sqlite3 "$DB" 'select max(id) from invocations')"
check "the blank problem is ignored" \
    "$(sqlite3 "$DB" "select count(*) from problems where invocation_id = $ID")" "2"
check "the problems are in order and attached" \
    "$(sqlite3 "$DB" "select group_concat(problem, '|') from problems where invocation_id = $ID")" \
    "first issue|second issue"
check "the row carries the skill" \
    "$(sqlite3 "$DB" "select skill from invocations where id = $ID")" "demo"
check "the row carries a local ISO 8601 stamp with an offset" \
    "$(sqlite3 "$DB" "select ts from invocations where id = $ID" \
        | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"

# A newline in a problem must not split it into two lines on read.
run add --skill demo --problem "$(printf 'line one\nline two')"
check "a newline in a problem exits 0" "$STATUS" "0"
check "a control character cannot split a problem into two lines" \
    "$(sqlite3 "$DB" "select count(*) from problems where problem like '%line one%line two%'")" "1"

# `add` is deliberately not idempotent: two identical calls, two rows.
BEFORE="$(sqlite3 "$DB" 'select count(*) from invocations')"
run add --skill duplicate
run add --skill duplicate
AFTER="$(sqlite3 "$DB" 'select count(*) from invocations')"
check "two identical calls produce two rows" "$AFTER" "$((BEFORE + 2))"

# ----------------------------------------------------------------- marker

case "$OUT" in
    *"#"*) pass "the marker is machine#id" ;;
    *) fail "the marker is not machine#id: '$OUT'" ;;
esac

# ---------------------------------------------------------------- dry run

rm -rf "$SCRATCH/preview"
mkdir -p "$SCRATCH/preview/home"
OUT="$(env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$SCRATCH/preview/home" \
    "$BIN" add --skill preview --dry-run --json --problem "not written")"
STATUS=$?
check "dry-run exits 0" "$STATUS" "0"
if [ -e "$SCRATCH/preview/home/.local/state/skill-log" ]; then
    fail "dry-run created the state directory"
else
    pass "dry-run writes nothing"
fi
check "dry-run reports id null" \
    "$(printf '%s' "$OUT" | grep -c '"id":null')" "1"
check "dry-run carries no marker" \
    "$(printf '%s' "$OUT" | grep -c '"marker":""')" "1"

# ------------------------------------------------------------------- json

run add --skill json --json --problem "one"
check "json exits 0" "$STATUS" "0"
check "json is one flat object" \
    "$(printf '%s' "$OUT" | grep -c '^{.*}$')" "1"
check "json carries every column" \
    "$(printf '%s' "$OUT" | grep -o '"\(id\|ts\|skill\|parent\|model\|project\|t3_thread\|opencode_thread\|worktree\|machine\|fix\|resolved_at\|marker\|problems\)":' | wc -l)" \
    "14"
check "json carries the problems array" \
    "$(printf '%s' "$OUT" | grep -c '"problems":\["one"\]')" "1"

# -------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
BEFORE_SUM="$(md5sum <"$SCRATCH/damaged.db")"
run add --skill x --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "a damaged store is named" \
    "$(printf '%s' "$ERR" | grep -c 'damaged store')" "1"
check "a damaged store is one line" "$(err_lines)" "1"
check "a damaged store is not written" "$(md5sum <"$SCRATCH/damaged.db")" "$BEFORE_SUM"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
BEFORE_SUM="$(md5sum <"$SCRATCH/foreign.db")"
run add --skill x --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "a foreign store is named" \
    "$(printf '%s' "$ERR" | grep -c 'foreign store')" "1"
check "a foreign store is one line" "$(err_lines)" "1"
check "a foreign store is not converted" "$(md5sum <"$SCRATCH/foreign.db")" "$BEFORE_SUM"

cp "$DB" "$SCRATCH/newer.db"
sqlite3 "$SCRATCH/newer.db" 'pragma user_version=99'
run add --skill x --db "$SCRATCH/newer.db"
check "a newer store exits 1" "$STATUS" "1"
check "a newer store is named with both versions" \
    "$(printf '%s' "$ERR" | grep -c 'has schema version 99.*understands 1')" "1"
check "a newer store is one line" "$(err_lines)" "1"

# ----------------------------------------------------------- atomic write

BEFORE="$(sqlite3 "$DB" 'select count(*) from invocations')"
chmod 444 "$DB" "$DB-wal" "$DB-shm" 2>/dev/null
run add --skill unwritable --problem "must not land"
STATUS_LOCKED=$STATUS
chmod 644 "$DB" "$DB-wal" "$DB-shm" 2>/dev/null
check "a failed write exits 1" "$STATUS_LOCKED" "1"
check "a failed write leaves no row behind" \
    "$(sqlite3 "$DB" 'select count(*) from invocations')" "$BEFORE"
check "a failed write is one line" \
    "$(printf '%s' "$(cat "$SCRATCH/stderr")" | grep -c .)" "1"

# ------------------------------------------------------------ precedence

env -u XDG_STATE_HOME SKILL_LOG_DB="$SCRATCH/env.db" HOME="$HOME_DIR" \
    "$BIN" add --skill precedence --db "$SCRATCH/flag.db" >/dev/null
if [ -f "$SCRATCH/flag.db" ] && [ ! -e "$SCRATCH/env.db" ]; then
    pass "--db beats SKILL_LOG_DB"
else
    fail "--db did not beat SKILL_LOG_DB"
fi

env -u XDG_STATE_HOME -u SKILL_LOG_DB XDG_STATE_HOME="$SCRATCH/state" \
    HOME="$HOME_DIR" "$BIN" add --skill xdg >/dev/null
if [ -f "$SCRATCH/state/skill-log/skills.db" ]; then
    pass "XDG_STATE_HOME is honoured"
else
    fail "XDG_STATE_HOME was not honoured"
fi

env -u XDG_STATE_HOME SKILL_LOG_DB="$SCRATCH/env.db" HOME="$HOME_DIR" \
    "$BIN" add --skill precedence >/dev/null
if [ -f "$SCRATCH/env.db" ]; then
    pass "SKILL_LOG_DB is honoured"
else
    fail "SKILL_LOG_DB was not honoured"
fi

# ----------------------------------------------------------- usage errors

run add
check "add without --skill is a usage error" "$STATUS" "2"
check "a usage error is one line" "$(err_lines)" "1"

run add --skill x --nope
check "an unknown flag is a usage error" "$STATUS" "2"

# ----------------------------------------------------------------- report

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
