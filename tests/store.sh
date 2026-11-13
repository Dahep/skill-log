#!/usr/bin/env bash
# The store test: `add` against the built artifact, in a sandboxed home.
#
#   tests/store.sh
#
# It exercises the seam the contract is written against — the installed
# binary as a process — with a temporary HOME, a temporary XDG state
# directory, and no real store anywhere near it. The CLI is the only
# writer; the store file is inspected with the sqlite3 CLI where a case
# needs to see what was written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-store-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a caller's
# SCRATCH is theirs to clean up.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools sqlite3 python3

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
check "the row carries a local ISO 8601 stamp with an offset" \
    "$(sqlite3 "$DB" 'select ts from invocations order by id limit 1' \
        | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"

PARALLEL_DB="$SCRATCH/parallel.db"
PARALLEL_ERR="$SCRATCH/parallel.err"
: >"$PARALLEL_ERR"
for _ in 1 2 3 4 5 6; do
    env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$HOME_DIR" \
        "$BIN" add --skill parallel --db "$PARALLEL_DB" >/dev/null 2>>"$PARALLEL_ERR" &
done
wait
check "six concurrent first writes all land" \
    "$(sqlite3 "$PARALLEL_DB" 'select count(*) from invocations')" "6"
check "no concurrent writer refused the half-built store" \
    "$(wc -l <"$PARALLEL_ERR" | tr -d ' ')" "0"
check "the concurrent store has both tables" \
    "$(sqlite3 "$PARALLEL_DB" \
        "select count(*) from sqlite_master where type='table'
            and name in ('invocations','problems')")" "2"

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

run add --skill demo --problem "$(printf 'line one\nline two')"
check "a newline in a problem exits 0" "$STATUS" "0"
NEWLINE_ID="$(sqlite3 "$DB" 'select max(id) from invocations')"
check "a control character is replaced, not stored" \
    "$(sqlite3 "$DB" "select count(*) from problems where invocation_id = $NEWLINE_ID
        and problem like '%'||char(10)||'%'")" "0"
check "the problem text is one line after the write" \
    "$(sqlite3 "$DB" "select problem from problems where invocation_id = $NEWLINE_ID")" \
    "line one line two"

BEFORE="$(sqlite3 "$DB" 'select count(*) from invocations')"
run add --skill duplicate
run add --skill duplicate
AFTER="$(sqlite3 "$DB" 'select count(*) from invocations')"
check "two identical calls produce two rows" "$AFTER" "$((BEFORE + 2))"

run add --skill helpval --problem -h
check "a problem spelled -h is recorded" "$STATUS" "0"
check "the problem value -h reaches the store" \
    "$(sqlite3 "$DB" "select problem from problems
        where invocation_id = (select max(id) from invocations)")" "-h"

python3 -c "import sys; sys.stdout.write('a'*65536)" | \
    env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$HOME_DIR" \
    "$BIN" add --skill stdin --problem - >/dev/null 2>"$SCRATCH/stderr"
check "a full-buffer stdin pipe exits 0" "$?" "0"
STDIN_ID="$(sqlite3 "$DB" 'select max(id) from invocations')"
check "a full-buffer stdin pipe stores every byte" \
    "$(sqlite3 "$DB" "select length(problem) from problems where invocation_id = $STDIN_ID")" \
    "65536"
check "a full-buffer stdin pipe stores nothing beyond the pipe" \
    "$(sqlite3 "$DB" "select count(*) from problems where invocation_id = $STDIN_ID
        and problem glob '*[^a]*'")" "0"

( printf 'first part'; printf ' second part\n' ) | \
    env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$HOME_DIR" \
    "$BIN" add --skill stdin --problem - >/dev/null 2>"$SCRATCH/stderr"
check "a pipe written in two chunks exits 0" "$?" "0"
check "a pipe written in two chunks keeps both parts" \
    "$(sqlite3 "$DB" "select problem from problems
        where invocation_id = (select max(id) from invocations)")" \
    "first part second part"

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

# ------------------------------------------------------------ clock

OUT="$(env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$HOME_DIR" \
    SKILL_LOG_NOW=2020-01-02T03:04:05+00:00 \
    "$BIN" add --skill pinned --json)"
STATUS=$?
check "SKILL_LOG_NOW exits 0" "$STATUS" "0"
check "SKILL_LOG_NOW pins the row's timestamp" \
    "$(json_field "$OUT" ts)" "2020-01-02T03:04:05+00:00"

# ------------------------------------------------------------------- json

run add --skill json --json --problem "one"
check "json exits 0" "$STATUS" "0"
check "json is one flat object" \
    "$(printf '%s' "$OUT" | grep -c '^{.*}$')" "1"
check "json carries exactly the row's keys" "$(json_keys "$OUT")" \
    "fix harness id machine marker model parent problems project repo resolved_at session skill t3_thread ts worktree"
check "json carries the problems array" \
    "$(json_problem "$OUT")" "one"

# -------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
BEFORE_SUM="$(md5sum <"$SCRATCH/damaged.db")"
run add --skill x --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "a damaged store is named" \
    "$(printf '%s' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "a damaged store is one line" "$ERR"
check "a damaged store is not written" "$(md5sum <"$SCRATCH/damaged.db")" "$BEFORE_SUM"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
BEFORE_SUM="$(md5sum <"$SCRATCH/foreign.db")"
run add --skill x --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "a foreign store is named" \
    "$(printf '%s' "$ERR" | grep -c 'foreign store')" "1"
check_one_line "a foreign store is one line" "$ERR"
check "a foreign store is not converted" "$(md5sum <"$SCRATCH/foreign.db")" "$BEFORE_SUM"

cp "$DB" "$SCRATCH/newer.db"
sqlite3 "$SCRATCH/newer.db" 'pragma user_version=99'
run add --skill x --db "$SCRATCH/newer.db"
check "a newer store exits 1" "$STATUS" "1"
check "a newer store is named with both versions" \
    "$(printf '%s' "$ERR" | grep -c 'has schema version 99.*understands 1')" "1"
check_one_line "a newer store is one line" "$ERR"

cp "$DB" "$SCRATCH/wrong-problems.db"
sqlite3 "$SCRATCH/wrong-problems.db" \
    'drop table problems; create table problems (dummy TEXT)'
BEFORE_SUM="$(md5sum <"$SCRATCH/wrong-problems.db")"
run add --skill x --db "$SCRATCH/wrong-problems.db"
check "a store with the wrong problems table exits 1" "$STATUS" "1"
check "a store with the wrong problems table is foreign" \
    "$(printf '%s' "$ERR" | grep -c 'foreign store')" "1"
check "a store with the wrong problems table is not written" \
    "$(md5sum <"$SCRATCH/wrong-problems.db")" "$BEFORE_SUM"

sqlite3 "$SCRATCH/older.db" <<'SQL'
CREATE TABLE invocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    skill TEXT NOT NULL,
    parent TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '',
    t3_thread TEXT NOT NULL DEFAULT '',
    opencode_thread TEXT NOT NULL DEFAULT '',
    worktree TEXT NOT NULL DEFAULT '',
    machine TEXT NOT NULL DEFAULT '',
    fix TEXT NOT NULL DEFAULT '',
    resolved_at TEXT NOT NULL DEFAULT '',
    origin_id INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE problems (
    invocation_id INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    problem TEXT NOT NULL,
    PRIMARY KEY (invocation_id, ordinal)
);
INSERT INTO invocations (ts, skill, machine)
    VALUES ('2026-01-01T00:00:00+00:00', 'old', 'other');
SQL
BEFORE_SUM="$(md5sum <"$SCRATCH/older.db")"
run add --skill x --db "$SCRATCH/older.db"
check "an older store exits 1" "$STATUS" "1"
check "an older store is named as older" \
    "$(printf '%s' "$ERR" | grep -c 'older store')" "1"
check "an older store says it is not converted" \
    "$(printf '%s' "$ERR" | grep -c 'does not convert it')" "1"
check_one_line "an older store is one line" "$ERR"
check "an older store is not converted" "$(md5sum <"$SCRATCH/older.db")" "$BEFORE_SUM"
check "the older row is still there untouched" \
    "$(sqlite3 "$SCRATCH/older.db" 'select count(*) from invocations')" "1"

printf 'not a directory' >"$SCRATCH/not-a-dir"
for pair in "older:older store" "newer5:newer store" \
    "foreign:foreign store" "damaged:damaged store"; do
    word="${pair%%:*}"
    phrase="${pair##*:}"
    run add --skill x --db "$SCRATCH/not-a-dir/$word/store.db"
    check "a path named $word still exits 1" "$STATUS" "1"
    check_absent "a path named $word is not reported as a $phrase" "$ERR" "$phrase"
    check_contains "a path named $word names the directory" "$ERR" "not-a-dir"
    check_one_line "a path named $word is one line" "$ERR"
done

WEIRD_DB="$SCRATCH/$(printf 'weird\npath').db"
printf 'not a database' >"$WEIRD_DB"
run add --skill x --db "$WEIRD_DB"
check "a damaged store with a newline in its path is named" \
    "$(printf '%s' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "a newline in a path does not split the diagnostic" "$ERR"

for word in malformed older locked foreign newer; do
    OPEN_DIR="$SCRATCH/openfail/$word/store.db"
    mkdir -p "$OPEN_DIR/inside"
    run add --skill x --db "$OPEN_DIR"
    check "a path named $word cannot be opened: exits 1" "$STATUS" "1"
    check_absent "a path named $word is not reported as damaged" \
        "$ERR" "damaged store"
    check_absent "a path named $word is not reported as older" \
        "$ERR" "older store"
    check_absent "a path named $word is not reported as foreign" \
        "$ERR" "foreign store"
    check_absent "a path named $word is not reported as locked" \
        "$ERR" "locked store"
    check_absent "a path named $word is not reported as newer" \
        "$ERR" "newer store"
    check_contains "a path named $word names the path" "$ERR" "$word"
    check_one_line "a path named $word is one line" "$ERR"
done

NOREAD_DIR="$SCRATCH/noread/malformed"
mkdir -p "$NOREAD_DIR"
printf 'not a database' >"$NOREAD_DIR/store.db"
chmod 000 "$NOREAD_DIR/store.db"
run show --db "$NOREAD_DIR/store.db"
check "an unopenable store exits 1" "$STATUS" "1"
check_absent "an unopenable store under a vocabulary path is not damage" \
    "$ERR" "damaged store"
check_absent "an unopenable store under a vocabulary path is not older" \
    "$ERR" "older store"
check_contains "an unopenable store names the path" "$ERR" "malformed"
check_one_line "an unopenable store is one line" "$ERR"
chmod 0644 "$NOREAD_DIR/store.db"

# ----------------------------------------------------------- atomic write

BEFORE="$(sqlite3 "$DB" 'select count(*) from invocations')"
chmod 444 "$DB" "$DB-wal" "$DB-shm" 2>/dev/null
run add --skill unwritable --problem "must not land"
STATUS_LOCKED=$STATUS
chmod 644 "$DB" "$DB-wal" "$DB-shm" 2>/dev/null
check "a failed write exits 1" "$STATUS_LOCKED" "1"
check "a failed write leaves no row behind" \
    "$(sqlite3 "$DB" 'select count(*) from invocations')" "$BEFORE"
check_one_line "a failed write is one line" "$ERR"

RODIR2="$SCRATCH/readonly-writes"
rm -rf "$RODIR2"
mkdir -p "$RODIR2"
RO_DB2="$RODIR2/skills.db"
run add --skill fixture --db "$RO_DB2"
check "the read-only fixture is written" "$STATUS" "0"
chmod 0444 "$RO_DB2"
chmod 0555 "$RODIR2"

run add --skill never-written --db "$RO_DB2"
check "a write to a read-only store exits 1" "$STATUS" "1"
check_contains "the read-only store is named" "$ERR" "read-only store"
check_absent "the read-only store leaks no SQL" "$ERR" "sqlite3_exec"
check_absent "the read-only store leaks no SQL rc" "$ERR" "sqlite3 rc="
check_one_line "the read-only store's refusal is one line" "$ERR"

run resolve --id 1 --fix abc1234 --db "$RO_DB2"
check "a resolve against a read-only store exits 1" "$STATUS" "1"
check_contains "the read-only store is named by resolve" "$ERR" \
    "read-only store"
check_absent "resolve leaks no SQL" "$ERR" "sqlite3_exec"

chmod 0755 "$RODIR2"
chmod 0644 "$RO_DB2"

RO_WORD_DIR="$SCRATCH/readonly-word/older"
mkdir -p "$RO_WORD_DIR"
run add --skill fixture --db "$RO_WORD_DIR/store.db"
check "the vocabulary path fixture is written" "$STATUS" "0"
chmod 0444 "$RO_WORD_DIR/store.db"
run add --skill x --db "$RO_WORD_DIR/store.db"
check "a read-only store under a vocabulary path exits 1" "$STATUS" "1"
check_contains "the read-only store is still named as read-only" "$ERR" \
    "read-only store"
check_absent "the vocabulary path did not make it an older store" \
    "$ERR" "older store"
check_absent "the vocabulary path did not make it a damaged store" \
    "$ERR" "damaged store"
chmod 0644 "$RO_WORD_DIR/store.db"

UNOPENABLE="$SCRATCH/unopenable"
rm -rf "$UNOPENABLE"
mkdir -p "$UNOPENABLE/adir"

run add --skill fixture --db "$UNOPENABLE/adir"
check "a store path that cannot be opened exits 1" "$STATUS" "1"
check_contains "a store path that cannot be opened is named" "$ERR" \
    "unusable store path: $UNOPENABLE/adir"
check_absent "a store path that cannot be opened leaks no SQL rc" "$ERR" \
    "sqlite3 rc="
check_absent "a store path that cannot be opened leaks no engine text" \
    "$ERR" "sqlite3_open("
check_one_line "the unopenable store's refusal is one line" "$ERR"

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
check_one_line "a usage error is one line" "$ERR"

run add --skill x --nope
check "an unknown flag is a usage error" "$STATUS" "2"

LOCKDIR="$SCRATCH/locked"
mkdir -p "$LOCKDIR"
LOCK_DB="$LOCKDIR/skills.db"
run add --skill lock-holder --db "$LOCK_DB"
check "the locked fixture is written" "$STATUS" "0"

hold_lock "$LOCK_DB" "$SCRATCH/lock-ready" 12 &
HOLDER=$!
wait_for "$SCRATCH/lock-ready"
run add --skill never-landed --db "$LOCK_DB"
check "a write behind a lock exits 1" "$STATUS" "1"
check_contains "a write behind a lock is named as a locked store" \
    "$ERR" "locked store"
check_one_line "the locked store's refusal is one line" "$ERR"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null

VOCAB_DIR="$SCRATCH/vocabulary"
rm -rf "$VOCAB_DIR"
mkdir -p "$VOCAB_DIR"

(
    cd "$VOCAB_DIR" || exit 1
    "$BIN" add --skill lock-holder --db locked >/dev/null 2>&1
)
hold_lock "$VOCAB_DIR/locked" "$SCRATCH/vocab-lock-ready" 3 &
HOLDER=$!
wait_for "$SCRATCH/vocab-lock-ready"
(
    cd "$VOCAB_DIR" || exit 1
    "$BIN" add --skill after-the-lock --db locked >/dev/null 2>&1
)
VOCAB_STATUS=$?
wait "$HOLDER" 2>/dev/null
check "a store path named 'locked' retries the lock" "$VOCAB_STATUS" "0"
check "the write behind the lock landed" \
    "$(sqlite3 "$VOCAB_DIR/locked" "SELECT COUNT(*) FROM invocations WHERE skill = 'after-the-lock'")" "1"

python3 - "$VOCAB_DIR/malformed" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE t (x)")
db.commit()
db.close()
with open(sys.argv[1], "r+b") as handle:
    handle.seek(100)
    handle.write(b"\xff" * 800)
PY
(
    cd "$VOCAB_DIR" || exit 1
    "$BIN" add --skill never-written --db malformed >/dev/null 2>"$SCRATCH/stderr"
)
STATUS=$?
ERR="$(cat "$SCRATCH/stderr")"
check "a corrupt store path named 'malformed' exits 1" "$STATUS" "1"
check_contains "a corrupt store path named 'malformed' is damaged" "$ERR" \
    "damaged store"
check_absent "a corrupt store path named 'malformed' is not generic" \
    "$ERR" "cannot write the store"

(
    cd "$VOCAB_DIR" || exit 1
    "$BIN" add --skill healthy --db malformed-healthy >/dev/null 2>"$SCRATCH/stderr"
)
STATUS=$?
ERR="$(cat "$SCRATCH/stderr")"
check "a healthy store path named 'malformed' is written" "$STATUS" "0"
check_absent "a healthy store path named 'malformed' is not damage" \
    "$ERR" "damaged store"

RODIR="$SCRATCH/readonly"
chmod -R 0755 "$RODIR" 2>/dev/null
rm -rf "$RODIR"
mkdir -p "$RODIR"
RO_DB="$RODIR/skills.db"
run add --skill read-only --db "$RO_DB"
check "the read-only fixture is written" "$STATUS" "0"
sqlite3 "$RO_DB" 'PRAGMA journal_mode=DELETE;' >/dev/null
rm -f "$RO_DB-wal" "$RO_DB-shm"
chmod 0444 "$RO_DB"
chmod 0555 "$RODIR"
RO_BEFORE="$(md5sum <"$RO_DB")"
RO_MTIME="$(stat -c %Y "$RO_DB")"
sleep 1
run show --db "$RO_DB" --json
check "a read of a store with no write permission exits 0" "$STATUS" "0"
check "a read of a store with no write permission reads the rows" \
    "$(json_field "$OUT" skill)" "read-only"
check "the read left the store's bytes alone" \
    "$(md5sum <"$RO_DB")" "$RO_BEFORE"
check "the read left the store's mtime alone" \
    "$(stat -c %Y "$RO_DB")" "$RO_MTIME"
SIDECARS=0
for sidecar in "$RODIR"/skills.db-*; do
    [ -e "$sidecar" ] && SIDECARS=$((SIDECARS + 1))
done
check "the read created no sidecar" "$SIDECARS" "0"
chmod 0755 "$RODIR"
chmod 0644 "$RO_DB"

ABSENT="$SCRATCH/absent/db/skills.db"
run show --db "$ABSENT"
check "a read of an absent store exits 0" "$STATUS" "0"
check "a read of an absent store is the empty message" "$OUT" \
    "no invocations logged yet"
check "a read of an absent store created no store" \
    "$([ -e "$ABSENT" ] && echo created || echo absent)" "absent"
check "a read of an absent store created no directory" \
    "$([ -d "$SCRATCH/absent" ] && echo created || echo absent)" "absent"

# ----------------------------------------------------------------- report

tally
