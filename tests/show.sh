#!/usr/bin/env bash
# The show test: reading the log back, in a sandboxed home.
#
#   tests/show.sh
#
# It exercises the read half of the CLI against the built artifact, with
# a temporary HOME and a temporary store, so nothing reaches the real
# log. The CLI is the only writer; the sqlite3 CLI is used to look at
# what a write left behind, never to change it.
#
# Cases: the absent and the empty store, the empty JSON stream, the
# table and its indentation, every filter, --run across the three
# namespaces, the ordering, --last, the home shortening, the refusals,
# the usage errors, and — the invariant the whole verb rests on — a read
# that changes nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-show-XXXXXX)}"
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
    printf 'show.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
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

# run <args...>: the binary with no inherited store configuration. Output
# lands in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# ------------------------------------------------------------ absent store

run show
check "an absent store exits 0" "$STATUS" "0"
check "an absent store says so" "$OUT" "no invocations logged yet"
if [ -e "$HOME_DIR/.local/state" ]; then
    fail "a read created the state directory"
else
    pass "a read creates no state directory"
fi
if [ -e "$DB" ]; then
    fail "a read created the store"
else
    pass "a read creates no store"
fi

# The JSON stream of an absent store is empty: not a line, not a blank
# line, no bytes at all.
"$BIN" show --json >"$SCRATCH/absent.json" 2>"$SCRATCH/stderr"
check "an absent store in json exits 0" "$?" "0"
check "an absent store in json prints nothing" \
    "$(wc -c <"$SCRATCH/absent.json" | tr -d ' ')" "0"
check "an absent store in json is quiet on stderr" \
    "$(wc -c <"$SCRATCH/stderr" | tr -d ' ')" "0"

# ------------------------------------------------------------- empty store

# A store that exists but holds no rows: the same answer as an absent
# one, and the file is left as it was.
sqlite3 "$SCRATCH/empty.db" <<'SQL'
CREATE TABLE invocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    skill TEXT NOT NULL,
    harness TEXT NOT NULL DEFAULT '',
    session TEXT NOT NULL DEFAULT '',
    parent TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    repo TEXT NOT NULL DEFAULT '',
    worktree TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '',
    t3_thread TEXT NOT NULL DEFAULT '',
    machine TEXT NOT NULL DEFAULT '',
    fix TEXT NOT NULL DEFAULT '',
    resolved_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE problems (
    invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    problem TEXT NOT NULL,
    PRIMARY KEY (invocation_id, ordinal)
);
PRAGMA user_version=1;
SQL
run show --db "$SCRATCH/empty.db"
check "an empty store exits 0" "$STATUS" "0"
check "an empty store says so" "$OUT" "no invocations logged yet"
"$BIN" show --db "$SCRATCH/empty.db" --json >"$SCRATCH/empty.json" 2>/dev/null
check "an empty store in json prints nothing" \
    "$(wc -c <"$SCRATCH/empty.json" | tr -d ' ')" "0"

# A file that exists but was never initialised: no tables at all. SQLite
# treats it as an empty database, and so does the read — it is not a
# foreign store, because it holds nothing to be foreign.
: >"$SCRATCH/untouched.db"
run show --db "$SCRATCH/untouched.db"
check "an untouched empty file exits 0" "$STATUS" "0"
check "an untouched empty file says the log is empty" "$OUT" \
    "no invocations logged yet"
check "an untouched empty file stays empty" \
    "$(wc -c <"$SCRATCH/untouched.db" | tr -d ' ')" "0"
"$BIN" show --db "$SCRATCH/untouched.db" --json \
    >"$SCRATCH/untouched.json" 2>/dev/null
check "an untouched empty file has an empty JSON stream" \
    "$(wc -c <"$SCRATCH/untouched.json" | tr -d ' ')" "0"

# ------------------------------------------------------------------- rows

# Three rows with different context, so every filter has something to
# cut. The worktree of the second row is under the sandbox home, so the
# shortening has something to shorten.
run add --skill alpha --machine box1 --harness opencode --session ses-1 \
    --model opencode-go/minimax-m3 --repo alpha-repo --worktree "$HOME_DIR/wt" \
    --problem "first issue" --problem "second issue"
check "the first row is written" "$STATUS" "0"
run add --skill beta --machine box2 --harness claude --session ses-2 \
    --parent ses-1 --repo beta-repo --worktree /elsewhere/beta
check "the second row is written" "$STATUS" "0"
run add --skill alpha --machine box1 --harness opencode --t3-thread thr-9 \
    --repo alpha-repo
check "the third row is written" "$STATUS" "0"

run show
check "show exits 0" "$STATUS" "0"
# A header, three invocations and the two problem lines of the first.
check "the table has a header, three rows and the problems" \
    "$(printf '%s\n' "$OUT" | grep -c .)" "6"
check "the table has exactly three invocation rows" \
    "$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+ ')" "3"
check_contains "the table names the skill column" "$OUT" "skill"
check_contains "the table names the problems column" "$OUT" "resolved_at"
check_contains "the table shows the session" "$OUT" "ses-1"
check_contains "the table shows the parent" "$OUT" "ses-1"
check_contains "the table shows the t3 thread" "$OUT" "thr-9"

# The problems are indented under their invocation, one per line, in
# order.
check "the first problem is indented" \
    "$(printf '%s\n' "$OUT" | grep -c '^    problem 1: first issue$')" "1"
check "the second problem is indented" \
    "$(printf '%s\n' "$OUT" | grep -c '^    problem 2: second issue$')" "1"

# The worktree under the home is shortened; one outside it is not.
# The tilde is the literal output, not a path to expand.
# shellcheck disable=SC2088
check_contains "the worktree under the home is shortened" "$OUT" "~/wt"
check_contains "a worktree outside the home is untouched" "$OUT" "/elsewhere/beta"

# A clean row carries no problem lines.
check "a clean row has no problem lines" \
    "$(printf '%s\n' "$OUT" | grep -c '^    problem')" "2"

# Empty columns in the middle still pad, so the table's right edge is
# trimmed: no line ends in whitespace a diff would carry forever.
check "the table leaves no trailing whitespace" \
    "$(printf '%s\n' "$OUT" | grep -c ' $')" "0"

# ------------------------------------------------------------------- json

run show --json
check "json exits 0" "$STATUS" "0"
check "json is one object per row" "$(printf '%s\n' "$OUT" | grep -c .)" "3"
# The key set is pinned, not counted: a count proves that many keys are
# there, not which. The expected string is the one `tests/store.sh` pins
# for the same object.
check "json carries exactly the row's keys" "$(json_keys "$(printf '%s\n' "$OUT" | head -1)")" \
    "fix harness id machine marker model parent problems project repo resolved_at session skill t3_thread ts worktree"
check "json carries the problems array" \
    "$(printf '%s\n' "$OUT" | grep -c '"problems":\["first issue","second issue"\]')" "1"
check "json carries the marker" \
    "$(printf '%s\n' "$OUT" | grep -c "\"marker\":\"box1#[0-9]*\"")" "2"
check "json carries no trailing blank line" \
    "$(printf '%s\n' "$OUT" | grep -c '^$')" "0"

# Every line is a JSON object on its own: the stream is JSON lines.
check "every json line is an object" \
    "$(printf '%s\n' "$OUT" | grep -c '^{.*}$')" "3"

# ---------------------------------------------------------------- filters

run show --skill alpha --json
check "--skill selects the alpha rows" "$(printf '%s\n' "$OUT" | grep -c .)" "2"
check "--skill selects no other row" \
    "$(printf '%s\n' "$OUT" | grep -c '"skill":"beta"')" "0"

run show --machine box2 --json
check "--machine selects the box2 row" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check "--machine selects the right row" \
    "$(printf '%s\n' "$OUT" | grep -c '"machine":"box2"')" "1"

run show --harness claude --json
check "--harness selects the claude row" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check "--harness selects the right row" \
    "$(printf '%s\n' "$OUT" | grep -c '"harness":"claude"')" "1"

run show --repo alpha-repo --json
check "--repo selects the alpha-repo rows" "$(printf '%s\n' "$OUT" | grep -c .)" "2"
check "--repo selects no other row" \
    "$(printf '%s\n' "$OUT" | grep -c '"repo":"beta-repo"')" "0"

run show --skill beta --json
check "--skill and the other filters compose" \
    "$(printf '%s\n' "$OUT" | grep -c '"skill":"beta"')" "1"

# A filter that matches nothing is not an error: it says so and exits 0.
run show --skill nosuch
check "a filter that matches nothing exits 0" "$STATUS" "0"
check "a filter that matches nothing says so" \
    "$OUT" "no invocations match --skill nosuch"
run show --skill nosuch --machine nosuchmachine
check "two filters that match nothing say so" \
    "$OUT" "no invocations match --skill nosuch and --machine nosuchmachine"
run show --machine nosuchmachine
check "a machine filter that matches nothing says so" \
    "$OUT" "no invocations match --machine nosuchmachine"

# Every filter has its own empty message. The log holds rows — the
# filter cut them all — so the message must not say the log is empty.
run show --harness nosuchharness
check "a harness filter that matches nothing names the harness" \
    "$OUT" "no invocations match --harness nosuchharness"
run show --repo nosuchrepo
check "a repo filter that matches nothing names the repo" \
    "$OUT" "no invocations match --repo nosuchrepo"
run show --run nosuchrun
check "a run filter that matches nothing names the run" \
    "$OUT" "no invocations match --run nosuchrun"

# The filters compose in the message too: a reader who gave two filters
# learns that both were applied.
run show --skill nosuch --harness nosuchharness
check "two filters that match nothing are both named" \
    "$OUT" "no invocations match --skill nosuch and --harness nosuchharness"

# ------------------------------------------------------------------- run

# --run names a run in whichever namespace it was recorded in: the
# session, the T3 thread or the parent.
run show --run ses-1 --json
check "--run matches the session" "$(printf '%s\n' "$OUT" | grep -c .)" "2"
check "--run matches the parent too" \
    "$(printf '%s\n' "$OUT" | grep -c '"parent":"ses-1"')" "1"
run show --run thr-9 --json
check "--run matches the t3 thread" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check "--run matches the right row" \
    "$(printf '%s\n' "$OUT" | grep -c '"t3_thread":"thr-9"')" "1"
run show --run ses-2 --json
check "--run matches the other session" "$(printf '%s\n' "$OUT" | grep -c .)" "1"

# ---------------------------------------------------------------- unresolved

# A row a commit has stamped is resolved; an unstamped one is not.
sqlite3 "$DB" "UPDATE invocations SET fix = 'abc123', resolved_at = '2026-01-01T00:00:00+00:00' WHERE id = 1"
run show --unresolved --json
check "--unresolved drops the resolved row" "$(printf '%s\n' "$OUT" | grep -c .)" "2"
check "--unresolved keeps the unresolved rows" \
    "$(printf '%s\n' "$OUT" | grep -c '"fix":"abc123"')" "0"
run show --json
check "without the filter every row comes back" "$(printf '%s\n' "$OUT" | grep -c .)" "3"

# --------------------------------------------------------------- ordering

# The rows are ordered by when the run happened, not by when it was
# written: `datetime(ts)` normalizes each row's own UTC offset.
sqlite3 "$DB" "UPDATE invocations SET ts = '2026-01-01T10:00:00+00:00' WHERE id = 1"
sqlite3 "$DB" "UPDATE invocations SET ts = '2026-01-01T09:00:00+00:00' WHERE id = 2"
sqlite3 "$DB" "UPDATE invocations SET ts = '2026-01-01T11:00:00+00:00' WHERE id = 3"
run show --json
check "the newest row comes first" \
    "$(printf '%s\n' "$OUT" | head -n1 | grep -o '"id":[0-9]*')" '"id":3'
check "the oldest row comes last" \
    "$(printf '%s\n' "$OUT" | tail -n1 | grep -o '"id":[0-9]*')" '"id":2'

# A row written later but stamped earlier sorts earlier: the stamp is
# what the order follows, not the id.
sqlite3 "$DB" "UPDATE invocations SET ts = '2026-01-01T12:00:00+00:00' WHERE id = 2"
run show --json
check "the stamp beats the id" \
    "$(printf '%s\n' "$OUT" | head -n1 | grep -o '"id":[0-9]*')" '"id":2'

# Two rows of the same instant: the id breaks the tie, newest id first.
sqlite3 "$DB" "UPDATE invocations SET ts = '2026-01-01T12:00:00+00:00' WHERE id = 3"
run show --json
check "a tie breaks by id, newest first" \
    "$(printf '%s\n' "$OUT" | head -n1 | grep -o '"id":[0-9]*')" '"id":3'

# ------------------------------------------------------------------- last

run show --last 1 --json
check "--last one shows one row" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
run show --last 2 --json
check "--last two shows two rows" "$(printf '%s\n' "$OUT" | grep -c .)" "2"

# The default is 20 rows: enough to see the recent shape of the log.
DEFAULT_DB="$SCRATCH/default.db"
for i in $(seq 1 25); do
    "$BIN" add --skill "skill-$i" --db "$DEFAULT_DB" >/dev/null
done
"$BIN" show --db "$DEFAULT_DB" --json >"$SCRATCH/default.json"
check "the default shows twenty rows" \
    "$(grep -c . <"$SCRATCH/default.json")" "20"
"$BIN" show --db "$DEFAULT_DB" --last 25 --json >"$SCRATCH/all.json"
check "--last lifts the default" "$(grep -c . <"$SCRATCH/all.json")" "25"
"$BIN" show --db "$DEFAULT_DB" --last 500 --json >"$SCRATCH/cap.json"
check "--last at the cap shows every row" \
    "$(grep -c . <"$SCRATCH/cap.json")" "25"

# ------------------------------------------------------------ sanitization

# A control character in a stored problem must not split it into two
# lines, in either shape: the table and the JSON stream both sanitize
# the way the store does.
python3 - "$DEFAULT_DB" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute(
    "INSERT INTO invocations (ts, skill, machine)"
    " VALUES ('2026-01-01T00:00:00+00:00', 'control', 'box')"
)
row_id = db.execute("select max(id) from invocations").fetchone()[0]
db.execute(
    "INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, 1, ?)",
    (row_id, "bad\x01char\nnewline"),
)
db.commit()
PY
run show --db "$DEFAULT_DB" --skill control
check "a control character stays on one line" \
    "$(printf '%s\n' "$OUT" | grep -c '^    problem 1: bad char newline$')" "1"
check "the control character split nothing" \
    "$(printf '%s\n' "$OUT" | grep -c '^    problem')" "1"
run show --db "$DEFAULT_DB" --skill control --json
check "json sanitizes the control character too" \
    "$(printf '%s\n' "$OUT" | grep -c '"problems":\["bad char newline"\]')" "1"

# ---------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
DAMAGED_SUM="$(md5sum <"$SCRATCH/damaged.db")"
run show --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "a damaged store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "a damaged store is one line" "$ERR"
check "a damaged store is not written" "$(md5sum <"$SCRATCH/damaged.db")" "$DAMAGED_SUM"
check "a damaged store prints nothing on stdout" "$OUT" ""

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
FOREIGN_SUM="$(md5sum <"$SCRATCH/foreign.db")"
run show --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "a foreign store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'foreign store')" "1"
check_one_line "a foreign store is one line" "$ERR"
check "a foreign store is not converted" "$(md5sum <"$SCRATCH/foreign.db")" "$FOREIGN_SUM"

# The Python-era store: the two tables, the old columns.
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
OLDER_SUM="$(md5sum <"$SCRATCH/older.db")"
run show --db "$SCRATCH/older.db"
check "an older store exits 1" "$STATUS" "1"
check "an older store is named as older" \
    "$(printf '%s\n' "$ERR" | grep -c 'older store')" "1"
check "an older store says it is not converted" \
    "$(printf '%s\n' "$ERR" | grep -c 'does not convert it')" "1"
check_one_line "an older store is one line" "$ERR"
check "an older store is not converted" "$(md5sum <"$SCRATCH/older.db")" "$OLDER_SUM"

cp "$DB" "$SCRATCH/newer.db"
sqlite3 "$SCRATCH/newer.db" 'pragma user_version=99'
run show --db "$SCRATCH/newer.db"
check "a newer store exits 1" "$STATUS" "1"
check "a newer store is named with both versions" \
    "$(printf '%s\n' "$ERR" | grep -c 'has schema version 99.*understands 1')" "1"
check_one_line "a newer store is one line" "$ERR"

# A writer that crashed after committing leaves frames in the WAL. A
# read must see them and must not checkpoint them into the database
# file: the main file stays byte-identical and the WAL stays in place.
sqlite3 "$DB" 'pragma wal_checkpoint(TRUNCATE)'
cp "$DB" "$SCRATCH/wal.db"
python3 - "$SCRATCH/wal.db" <<'PY'
import os
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("pragma journal_mode=wal")
con.execute("update invocations set skill = 'wal-edit' where id = 1")
con.commit()
# Exit without closing: the committed frames stay in the WAL.
os._exit(0)
PY
WAL_SUM="$(md5sum <"$SCRATCH/wal.db")"
run show --db "$SCRATCH/wal.db" --skill wal-edit --json
check "a read sees a crashed writer's committed row" \
    "$(json_field "$OUT" skill)" "wal-edit"
check "a read does not checkpoint the WAL into the store" \
    "$(md5sum <"$SCRATCH/wal.db")" "$WAL_SUM"
if [ -f "$SCRATCH/wal.db-wal" ]; then
    pass "the WAL is still there after a read"
else
    fail "a read removed the WAL"
fi

# ------------------------------------------------------------ usage errors

run show --nope
check "an unknown flag is a usage error" "$STATUS" "2"
check "an unknown flag is one named line" \
    "$(printf '%s\n' "$ERR" | grep -c '^skill-log: unknown option: --nope$')" "1"
check_one_line "an unknown flag is one line and no more" "$ERR"

run show --skill
check "a missing value is a usage error" "$STATUS" "2"
check_one_line "a missing value is one line" "$ERR"
run show --last
check "a missing --last value is a usage error" "$STATUS" "2"
check_one_line "a missing --last value is one line" "$ERR"
run show --run
check "a missing --run value is a usage error" "$STATUS" "2"
check_one_line "a missing --run value is one line" "$ERR"

run show --last abc
check "a non-integer --last is a usage error" "$STATUS" "2"
check_one_line "a non-integer --last is one line" "$ERR"
run show --last 0
check "--last 0 is a usage error" "$STATUS" "2"
check_one_line "--last 0 is one line" "$ERR"
run show --last -1
check "--last -1 is a usage error" "$STATUS" "2"
check_one_line "--last -1 is one line" "$ERR"
run show --last 501
check "--last above the cap is a usage error" "$STATUS" "2"
check_one_line "--last above the cap is one line" "$ERR"
run show --last 999999999999999999999999
check "a --last too long for an int is a usage error" "$STATUS" "2"
check_one_line "a --last too long for an int is one line" "$ERR"
run show --last 500
check "--last at the cap is accepted" "$STATUS" "0"

run show --skill ""
check "an empty filter value is a usage error" "$STATUS" "2"
run show --run ""
check "an empty run value is a usage error" "$STATUS" "2"

# A flag's value is taken as written: `--run -h` names the run `-h`, while
# a help flag elsewhere in the call is still a help request.
run show --run -h
check "a --run value spelled -h is a value, not a help request" "$STATUS" "0"
check "a --run value spelled -h filters on it" "$OUT" \
    "no invocations match --run -h"
run show --skill alpha -h
check "a help flag after a value still asks for help" "$STATUS" "0"
check "the help block is the verb's usage" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"

# The usage error names the flag and lists the valid choices, on one
# line. A reader who asked for a wrong value learns the right one
# without a second command.
run show --last abc
check_contains "the usage error names the flag" "$ERR" "--last"
check_contains "the usage error lists the valid choices" "$ERR" "1 and 500"
run show --last 0
check_contains "the too-small --last lists the valid choices" "$ERR" "1 and 500"
run show --last 501
check_contains "the too-large --last lists the valid choices" "$ERR" "1 and 500"

# A usage error keeps stdout empty: the answer belongs on stderr.
run show --last abc
check "a usage error keeps stdout empty" "$OUT" ""

# --------------------------------------------------------------- read-only

# The invariant the verb rests on: a read changes nothing. The store is
# byte-identical afterwards, its mtime is untouched, and no new file
# appears beside it.
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

run show
run show --json
run show --skill alpha
run show --run ses-1 --last 2

check "the store is byte-identical after a read" "$(md5sum <"$DB")" "$BEFORE_SUM"
check "the store's mtime is unchanged after a read" "$(stat -c %Y "$DB")" \
    "$BEFORE_MTIME"
check "a read creates no new file of its own" \
    "$(files_besides_sidecars)" "$BEFORE_FILES"

# The journal mode is not switched either: a read must not rewrite the
# store's header.
check "the journal mode is unchanged" "$(sqlite3 "$DB" 'pragma journal_mode')" "wal"

# A read never creates an empty database either. The file the flag
# names does not exist, and the read leaves it that way.
ABSENT="$SCRATCH/never-created.db"
run show --db "$ABSENT"
check "a read of an absent store exits 0" "$STATUS" "0"
if [ -e "$ABSENT" ]; then
    fail "a read created an empty database"
else
    pass "a read creates no empty database"
fi

# The help block is the verb's own text, and it documents every filter.
run show --help
check "show --help exits 0" "$STATUS" "0"
for flag in --skill --machine --harness --repo --run --unresolved --last \
    --json --db; do
    check_contains "show --help lists $flag" "$OUT" "$flag"
done
check "show --help ends with 2 to 4 real invocations" \
    "$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "3"
check_contains "show --help keeps the read-only note" "$OUT" "never writes"

# Nor does it create the directory that would hold one.
FRESH="$SCRATCH/fresh/state/skill-log/skills.db"
run show --db "$FRESH"
check "a read of a fresh path exits 0" "$STATUS" "0"
if [ -e "$SCRATCH/fresh" ]; then
    fail "a read created the store's directory"
else
    pass "a read creates no store directory"
fi

# A read that arrives while another process holds the write lock waits
# for it (the connection's busy timeout) instead of failing: a routine
# concurrent `add` must not turn a `show` into "database is locked".
#
# The lock is held by a real second process, and the case waits for that
# process to say it holds the lock — a handshake, not a sleep that hopes
# the other side got there first.
hold_lock "$DB" "$SCRATCH/lock-ready" 2 &
HOLDER=$!
wait_for "$SCRATCH/lock-ready"
run show --last 1
wait "$HOLDER"
check "a read waits for a concurrent writer" "$STATUS" "0"
check_absent "a read behind a writer reports no lock" "$ERR" "locked"

# ------------------------------------------------------------------ report

tally
