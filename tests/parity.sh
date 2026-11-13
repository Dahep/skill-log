#!/usr/bin/env bash
# The parity gate: the reference harness's behaviour, against the installed
# binary.
#
#   tests/parity.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools git sqlite3 python3

if [ ! -x "$BIN" ]; then
    printf 'parity.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

# ------------------------------------------------------------- the sandbox
#

#
sandbox_ok() {
    local base home
    base="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    home="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
    case "$base" in
        "$REAL_HOME" | "$REAL_HOME"/*) return 1 ;;
    esac
    case "$home" in
        "$base"/*) return 0 ;;
        *) return 1 ;;
    esac
}

REAL_HOME="$HOME"
if [ -d /tmp/opencode ]; then
    BASE="$(mktemp -d /tmp/opencode/skill-log-parity-XXXXXX)"
else
    BASE="$(mktemp -d)"
fi
trap 'rm -rf "$BASE" 2>/dev/null' EXIT

S="$BASE/stage"
mkdir -p "$S/home" "$S/db" "$S/repos"
if ! sandbox_ok "$BASE" "$S/home"; then
    printf 'parity.sh: refusing: sandbox %s and home %s are not a safe pair\n' \
        "$BASE" "$S/home" >&2
    exit 1
fi
export HOME="$S/home"

unset XDG_STATE_HOME XDG_CONFIG_HOME
unset SKILL_LOG_DB SKILL_LOG_TEMPLATE_DIR
unset SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME T3CODE_HOST T3CODE_PORT

DBT="$S/db"

# run <args...>: the binary as a process. Output lands in $OUT and $ERR,
# the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$S/stderr")"
    STATUS=$?
    ERR="$(cat "$S/stderr")"
}

run_in() {
    local dir="$1"
    shift
    OUT="$(cd "$dir" && "$BIN" "$@" 2>"$S/stderr")"
    STATUS=$?
    ERR="$(cat "$S/stderr")"
}

# say <case name>: the case's banner, so a reader can follow the run.
say() { printf '\n--- %s\n' "$1"; }

# skip <case name> <reason>: a case that is out of scope.
skip() {
    SKIPPED=$((SKIPPED + 1))
    printf 'skip %s: %s\n' "$1" "$2"
}

SKIPPED=0

# count_rows <db>: the number of invocation rows in a store.
count_rows() {
    sqlite3 "$1" 'SELECT COUNT(*) FROM invocations'
}

# fix_of <db> <id>: the commit a row carries, or the empty string.
fix_of() {
    sqlite3 "$1" "SELECT COALESCE(fix, '') FROM invocations WHERE id = $2"
}

new_repo() {
    local repo="$S/repos/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf '%s' "$repo"
}

# commit_trailers <repo> <subject> <trailer>: one commit whose last
# paragraph is the marker block.
commit_trailers() {
    local repo="$1" subject="$2" trailer="$3" n
    n="$(date +%s%N)"
    printf '%s' "$n" >"$repo/file"
    git -C "$repo" add file
    git -C "$repo" commit -q -m "$subject" -m "$trailer"
}

mkopdb() {
    mkdir -p "$HOME/.local/share/opencode"
    sqlite3 "$HOME/.local/share/opencode/opencode.db" <<SQL
CREATE TABLE IF NOT EXISTS session_v2 (id TEXT PRIMARY KEY, model TEXT);
INSERT OR REPLACE INTO session_v2 (id, model) VALUES ('$1', '$2');
SQL
}

# mkolderdb <path>: a pre-1.0 skill-log store — the reference's v1 shape:
# the two tables, the old columns.
mkolderdb() {
    sqlite3 "$1" <<'SQL'
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
    VALUES ('2026-01-01T00:00:00+00:00', 'old-skill', 'other');
PRAGMA user_version=1;
SQL
}

H="$(hostname)"

# =========================================================================
# =========================================================================

# --- case 1: the migration becomes the refusal parity ---------------------
say "parity: case 1 — an older store is refused, never converted"
V1DB="$DBT/c1.db"
mkolderdb "$V1DB"
BEFORE_SUM="$(md5sum <"$V1DB")"
run add --skill new-skill --model prov-a/m-old --db "$V1DB"
check "case 1: adding to an older store exits 1" "$STATUS" "1"
check "case 1: the older store is named" \
    "$(printf '%s' "$ERR" | grep -c 'older store')" "1"
check "case 1: the older store says it is not converted" \
    "$(printf '%s' "$ERR" | grep -c 'does not convert it')" "1"
check_one_line "case 1: the refusal is one line" "$ERR"
check "case 1: the older store is byte-identical" \
    "$(md5sum <"$V1DB")" "$BEFORE_SUM"
check "case 1: the older row is still there" \
    "$(count_rows "$V1DB")" "1"
check "case 1: the older row keeps its skill" \
    "$(sqlite3 "$V1DB" 'SELECT skill FROM invocations')" "old-skill"
run show --skill old-skill --db "$V1DB" --json
check "case 1: reading the older store exits 1" "$STATUS" "1"
check "case 1: the read names the older store" \
    "$(printf '%s' "$ERR" | grep -c 'older store')" "1"

# --- case 2: auto-detect from the local opencode store ---------------------
say "parity: case 2 — the model comes from the session store, with the adapter on"
C2="$DBT/c2.db"
mkopdb ses_fixture '{"id": "m-test", "providerID": "prov-x"}'
OUT="$(OPENCODE_SESSION_ID=ses_fixture "$BIN" add --skill probed-skill \
    --db "$C2" --json)"
check "case 2: the adapter is off by default, so the model is blank" \
    "$(json_field "$OUT" model)" ""
check "case 2: the adapter is off by default, so the harness is blank" \
    "$(json_field "$OUT" harness)" ""
OUT="$(OPENCODE_SESSION_ID=ses_fixture SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill probed-skill --db "$C2" --json)"
check "case 2: the model is filled from the session record" \
    "$(json_field "$OUT" model)" "prov-x/m-test"
check "case 2: the harness is filled from the environment" \
    "$(json_field "$OUT" harness)" "opencode"
check "case 2: the session is filled from the environment" \
    "$(json_field "$OUT" session)" "ses_fixture"
OUT="$(env -u OPENCODE_SESSION_ID "$BIN" add --skill anon-skill \
    --db "$C2" --json)"
check "case 2: no session id -> model empty" "$(json_field "$OUT" model)" ""
OUT="$(OPENCODE_SESSION_ID=ses_missing SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill unknown-skill --db "$C2" --json)"
check "case 2: unknown session -> model empty" "$(json_field "$OUT" model)" ""
check "case 2: an unknown session still fills the harness" \
    "$(json_field "$OUT" harness)" "opencode"

# --- case 3: no local store at all ----------------------------------------
say "parity: case 3 — the model stays empty when the session is in no local store"
rm -rf "$HOME/.local/share/opencode"
OUT="$(OPENCODE_SESSION_ID=ses_remote T3CODE_HOST=fake-api-host \
    T3CODE_PORT=9999 SKILL_LOG_ADAPTERS=opencode "$BIN" add \
    --skill remote-skill --db "$DBT/c3.db" --json)"
check "case 3: a foreign session -> model empty" \
    "$(json_field "$OUT" model)" ""
check "case 3: the session itself is still recorded" \
    "$(json_field "$OUT" session)" "ses_remote"
mkopdb ses_fixture '{"id": "m-test", "providerID": "prov-x"}'
OUT="$(OPENCODE_SESSION_ID=ses_fixture SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill override-skill --model prov-m/m-fix \
    --db "$DBT/c3.db" --json)"
check "case 3: --model wins over a reachable detection answer" \
    "$(json_field "$OUT" model)" "prov-m/m-fix"
OUT="$(OPENCODE_SESSION_ID=ses_fixture SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill override-skill --model prov-m/m-fix \
    --db "$DBT/c3.db" --dry-run --json)"
check "case 3: a dry run with --model keeps the same override" \
    "$(json_field "$OUT" model)" "prov-m/m-fix"

# --- case 4: read paths on a pre-migration db -----------------------------
say "parity: case 4 — reads of an older store name it, and never read it as empty"
V1R="$DBT/c4.db"
mkolderdb "$V1R"
run show --db "$V1R" --json
check "case 4: show on an older store exits 1" "$STATUS" "1"
check "case 4: the read names the older store" \
    "$(printf '%s' "$ERR" | grep -c 'older store')" "1"
check "case 4: the read prints no rows" "$OUT" ""
run stats --db "$V1R" --json
check "case 4: stats on an older store exits 1" "$STATUS" "1"
check "case 4: stats prints no rows" "$OUT" ""
CORRUPT="$DBT/c4-corrupt.db"
printf 'not a sqlite file at all' >"$CORRUPT"
run stats --db "$CORRUPT" --by-model
check "case 4: a corrupt store exits 1" "$STATUS" "1"
check "case 4: a corrupt store is named" \
    "$(printf '%s' "$ERR" | grep -c 'damaged store')" "1"
check_one_line "case 4: the damage is one line" "$ERR"
run show --db "$CORRUPT" --json
check "case 4: the corrupt store's json stream is empty" "$OUT" ""
check "case 4: the corrupt store's json exit is 1" "$STATUS" "1"

# --- case 5: show/stats surface the column without breaking the shape -----
say "parity: case 5 — show and stats expose the model without breaking the shape"
C4="$DBT/c5.db"
"$BIN" add --skill s1 --model prov-a/m-1 --db "$C4" >/dev/null
"$BIN" add --skill s1 --db "$C4" >/dev/null
"$BIN" add --skill s1 --problem "p" --db "$C4" >/dev/null
OUT="$("$BIN" show --db "$C4" --json | tail -n1)"
check "case 5: the oldest row keeps its explicit model" \
    "$(json_field "$OUT" model)" "prov-a/m-1"
check_contains "case 5: the table names the model column" \
    "$("$BIN" show --db "$C4" | head -n1)" "model"
OUT="$("$BIN" stats --db "$C4" --json)"
check "case 5: plain stats groups one (skill) row" \
    "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check_absent "case 5: the model does not leak into the default grouping" \
    "$OUT" '"model"'
OUT="$("$BIN" stats --db "$C4" --by model --json)"
check "case 5: two (skill, model) rows for two models" \
    "$(printf '%s\n' "$OUT" | grep -c .)" "2"
check "case 5: every row carries the model key" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; r=[json.loads(l) for l in sys.stdin]; print(all("model" in x for x in r))')" \
    "True"
check "case 5: the default table keeps the rate column" \
    "$("$BIN" stats --db "$C4" | grep -c 'problems/invocation')" "1"

# --- case 6: the parallel first write -------------------------------------
say "parity: case 6 — parallel first writes on one store both land"
C6="$DBT/c6.db"
"$BIN" add --skill race-a --model prov-p/m-a --db "$C6" >/dev/null &
RACE_A=$!
"$BIN" add --skill race-b --model prov-p/m-b --db "$C6" >/dev/null &
RACE_B=$!
RACE_OK=1
wait "$RACE_A" || RACE_OK=0
wait "$RACE_B" || RACE_OK=0
check "case 6: both adds succeed" "$RACE_OK" "1"
check "case 6: both rows landed" "$(count_rows "$C6")" "2"
check "case 6: both models landed" \
    "$(sqlite3 "$C6" 'SELECT COUNT(DISTINCT model) FROM invocations')" "2"

# --- case 7: --dry-run writes nothing -------------------------------------
say "parity: case 7 — a dry run previews and writes nothing"
C7="$DBT/c7.db"
OUT="$("$BIN" add --skill dry --model prov-a/m-dry --dry-run --db "$C7" --json)"
check "case 7: the preview shows the model" \
    "$(json_field "$OUT" model)" "prov-a/m-dry"
check "case 7: the preview carries no marker" \
    "$(json_field "$OUT" marker)" ""
if [ -e "$C7" ]; then
    fail "case 7: the dry run created the store"
else
    pass "case 7: the dry run created no store"
fi

# --- case 8: --parent rides end to end -------------------------------------
say "parity: case 8 — --parent lands on the row and reads back"
C8="$DBT/c8.db"
OUT="$("$BIN" add --skill research --parent thread_abc123 --db "$C8" --json)"
check "case 8: add --json echoes the parent" \
    "$(json_field "$OUT" parent)" "thread_abc123"
OUT="$("$BIN" show --db "$C8" --last 1 --json)"
check "case 8: show --json reads the parent back" \
    "$(json_field "$OUT" parent)" "thread_abc123"
check_contains "case 8: the show table carries the parent cell" \
    "$("$BIN" show --db "$C8" --last 1)" "thread_abc123"

# --- case 9: a snapshot that carries the model but not the parent ---------
say "parity: case 9: an older snapshot is refused, whatever its permissions"
C9="$DBT/c9.db"
mkolderdb "$C9"
chmod 444 "$C9"
run stats --db "$C9" --by model
check "case 9: the read-only older store exits 1" "$STATUS" "1"
check "case 9: the read-only older store is named" \
    "$(printf '%s' "$ERR" | grep -c 'older store')" "1"
check "case 9: the read-only older store prints no rows" "$OUT" ""
chmod 644 "$C9"

# --- case 10: a busy write is retried, not lost ---------------------------
#
say "parity: case 10 — a write survives a real second writer holding the lock"
C10="$DBT/c10.db"
"$BIN" add --skill lock-holder --db "$C10" >/dev/null
hold_lock "$C10" "$S/lock-ready" 3 &
LOCK_PID=$!
wait_for "$S/lock-ready"
run add --skill after-the-lock --db "$C10"
LOCK_STATUS=$STATUS
wait "$LOCK_PID" 2>/dev/null
check "case 10: the write behind the lock exits 0" "$LOCK_STATUS" "0"
check "case 10: the write behind the lock landed" \
    "$(sqlite3 "$C10" "SELECT COUNT(*) FROM invocations WHERE skill = 'after-the-lock'")" "1"
check "case 10: the lock holder's row is still there" \
    "$(sqlite3 "$C10" "SELECT COUNT(*) FROM invocations WHERE skill = 'lock-holder'")" "1"

# --- case 11: an exhausted retry fails quietly ----------------------------
say "parity: case 11 — an exhausted retry fails quietly, with one line"
C11="$DBT/c11.db"
"$BIN" add --skill lock-holder --db "$C11" >/dev/null
hold_lock "$C11" "$S/lock-ready-11" 120 &
LOCK_PID=$!
wait_for "$S/lock-ready-11"
run add --skill never-landed --db "$C11"
EXHAUST_STATUS=$STATUS
kill "$LOCK_PID" 2>/dev/null
wait "$LOCK_PID" 2>/dev/null
check "case 11: the exhausted write exits 1" "$EXHAUST_STATUS" "1"
check_one_line "case 11: the exhausted write is one stderr line" "$ERR"
check_absent "case 11: the failure is not a traceback" "$ERR" "Traceback"
check "case 11: the failed write landed no row" \
    "$(sqlite3 "$C11" "SELECT COUNT(*) FROM invocations WHERE skill = 'never-landed'")" "0"

# --- case 12: resolve marks a row and the resolved count follows ----------
say "parity: case 12 — resolve marks a row and the resolved count follows"
C12="$DBT/c12.db"
"$BIN" add --skill resolve-me --problem "p1" --db "$C12" >/dev/null
OUT="$("$BIN" resolve --id 1 --fix abc1234 --db "$C12" --json)"
check "case 12: resolve --json echoes the fix" \
    "$(json_field "$OUT" fix)" "abc1234"
OUT="$("$BIN" stats --db "$C12" --json)"
check "case 12: stats counts the resolved row" \
    "$(json_field "$OUT" resolved)" "1"
C12U="$DBT/c12-unresolved.db"
"$BIN" add --skill resolved-row --db "$C12U" >/dev/null
"$BIN" add --skill open-row --problem "still open" --db "$C12U" >/dev/null
"$BIN" resolve --id 1 --fix abc1234 --db "$C12U" >/dev/null
OUT="$("$BIN" show --unresolved --db "$C12U" --json)"
check "case 12: the unresolved filter lists only open rows" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.loads(l)["skill"] for l in sys.stdin))')" \
    "open-row"
"$BIN" resolve --id 1 --fix abc1234 --db "$C12" >/dev/null
OUT="$("$BIN" stats --db "$C12" --json)"
check "case 12: re-running leaves the same resolved count" \
    "$(json_field "$OUT" resolved)" "1"
run resolve --id 99 --fix abc1234 --db "$C12"
check "case 12: an unknown id exits 1" "$STATUS" "1"
check_contains "case 12: an unknown id is named" "$ERR" "no invocation 99"
check_one_line "case 12: an unknown id is one line" "$ERR"
run resolve --id 1 --fix abc1234 --db "$DBT/nope.db"
check "case 12: a missing store exits 1" "$STATUS" "1"
check_contains "case 12: a missing store is named" "$ERR" "no store at"
check_one_line "case 12: a missing store is one line" "$ERR"
OUT="$("$BIN" resolve --id 1 --fix deadbeef --db "$C12" --dry-run --json)"
check "case 12: a dry run previews the fix" \
    "$(json_field "$OUT" fix)" "deadbeef"
check "case 12: a dry run leaves the row's fix" \
    "$(fix_of "$C12" 1)" "abc1234"

# --- cases 13 to 17: the multi-machine sync cases --------------------------
skip "parity: case 13 — sync merges a remote log" \
    "multi-machine sync left scope in 1.0 (SPEC §10): no sync verb, no aggregate store, no owner authority"
skip "parity: case 14 — the pull reads a live WAL" \
    "multi-machine sync left scope in 1.0 (SPEC §10): there is no remote pull to read a WAL from"
skip "parity: case 15 — chained merges stay idempotent" \
    "multi-machine sync left scope in 1.0 (SPEC §10): there is no chain of aggregates to merge"
skip "parity: case 16 — a damaged log is named by the read paths" \
    "multi-machine sync left scope in 1.0 (SPEC §10): the case ran against sync's merge path, which does not exist; the damaged-store naming itself is ported in case 4 and the store matrix (case 26)"
skip "parity: case 17 — the default remote path needs no flag" \
    "multi-machine sync left scope in 1.0 (SPEC §10): there is no remote and no remote log path"

# --- case 18: a concurrent write's collision retries ----------------------
say "parity: case 18 — concurrent writers converge on one store"
C18="$DBT/c18.db"
for i in 1 2 3 4 5 6; do
    "$BIN" add --skill "collide-$i" --db "$C18" >/dev/null \
        2>"$S/c18-$i.err" &
done
wait
check "case 18: no concurrent writer failed" \
    "$(cat "$S"/c18-*.err | grep -c .)" "0"
check "case 18: every row landed exactly once" "$(count_rows "$C18")" "6"
check "case 18: the store kept one row per skill" \
    "$(sqlite3 "$C18" 'SELECT COUNT(DISTINCT skill) FROM invocations')" "6"

# --- case 19: resolve-merged stamps the rows a merged fix names -----------
say "parity: case 19 — resolve-merged stamps the rows a merged fix names"
R19="$(new_repo c19)"
DB19="$DBT/c19.db"
"$BIN" add --skill first-fix --db "$DB19" >/dev/null
"$BIN" add --skill second-fix --db "$DB19" >/dev/null
commit_trailers "$R19" "skills: fix two things" "Skill-log-Fix: $H#1, $H#2"
OUT="$(cd "$R19" && "$BIN" resolve-merged --db "$DB19" --json 2>/dev/null)"
check "case 19: both named rows are stamped" \
    "$(json_array "$OUT" resolved)" "$H#1,$H#2"
check "case 19: the stamp is the fix commit" \
    "$(fix_of "$DB19" 1)" "$(git -C "$R19" rev-parse HEAD)"
check "case 19: the second row carries the same commit" \
    "$(fix_of "$DB19" 2)" "$(git -C "$R19" rev-parse HEAD)"
check "case 19: stats counts both as resolved" \
    "$(sqlite3 "$DB19" "SELECT COUNT(*) FROM invocations WHERE fix <> ''")" "2"
OUT="$(cd "$R19" && "$BIN" resolve-merged --db "$DB19" --json 2>/dev/null)"
check "case 19: re-running stamps nothing" "$(json_array "$OUT" resolved)" ""
check "case 19: re-running names the rows it left alone" \
    "$(json_array "$OUT" unchanged)" "$H#1,$H#2"
#
GIT_COMMITTER_DATE="2020-01-01T00:00:00+0000" \
GIT_AUTHOR_DATE="2020-01-01T00:00:00+0000" \
    git -C "$R19" commit -q --allow-empty \
    -m "skills: name a row that does not exist yet" \
    -m "Skill-log-Fix: $H#3"
"$BIN" add --skill logged-later --db "$DB19" >/dev/null
run_in "$R19" resolve-merged --db "$DB19"
check "case 19: a row logged after the commit is skipped" "$STATUS" "0"
check_contains "case 19: the later row is guarded" "$ERR" \
    "$H#3 skipped: logged_after_commit"
check "case 19: the guarded row stays unresolved" "$(fix_of "$DB19" 3)" ""
commit_trailers "$R19" "skills: name things that are not ours" \
    "Skill-log-Fix: $H#99, $H#4, otherbox#4, <id>, 7"
run_in "$R19" resolve-merged --db "$DB19"
check_contains "case 19: an unknown id is named" "$ERR" \
    "$H#99 skipped: unknown_id"
check_contains "case 19: a placeholder is reported" "$ERR" \
    "not a Skill-log-Fix marker (machine#id): <id>"
check_contains "case 19: a bare id is refused" "$ERR" \
    "not a Skill-log-Fix marker (machine#id): 7"
check_contains "case 19: a foreign marker is reported" "$ERR" \
    "otherbox#4 skipped: foreign"
DB19S="$DBT/c19-since.db"
"$BIN" add --skill since-old --db "$DB19S" >/dev/null
commit_trailers "$R19" "skills: name the old row" "Skill-log-Fix: $H#1"
SINCE19="$(git -C "$R19" rev-parse HEAD)"
"$BIN" add --skill since-new --db "$DB19S" >/dev/null
commit_trailers "$R19" "skills: name a newer row" "Skill-log-Fix: $H#2"
OUT="$(cd "$R19" && "$BIN" resolve-merged --since "$SINCE19" --db "$DB19S" --json 2>/dev/null)"
check "case 19: --since only acts on what came after it" \
    "$(json_array "$OUT" resolved)" "$H#2"
check "case 19: the marker before --since left its row alone" \
    "$(fix_of "$DB19S" 1)" ""
DB19D="$DBT/c19-dry.db"
"$BIN" add --skill dry-run --db "$DB19D" >/dev/null
commit_trailers "$R19" "skills: name the dry-run row" "Skill-log-Fix: $H#1"
OUT="$(cd "$R19" && "$BIN" resolve-merged --db "$DB19D" --dry-run --json)"
check "case 19: a dry run reports the row it would stamp" \
    "$(json_array "$OUT" resolved)" "$H#1"
check "case 19: a dry run leaves the row unresolved" "$(fix_of "$DB19D" 1)" ""

# --- case 20: one machine, one identity -----------------------------------
say "parity: case 20 — a marker names its machine exactly"
R20="$(new_repo c20)"
C20L="$DBT/c20.db"
"$BIN" add --skill boxed --machine "$H" --db "$C20L" >/dev/null
printf x >"$R20/f"
git -C "$R20" add f
git -C "$R20" commit -q -m "skills: fix the box row" \
    -m "Skill-log-Fix: box.example.com#1"
OUT="$(cd "$R20" && "$BIN" resolve-merged --db "$C20L" --json 2>/dev/null)"
check "case 20: a differently spelled host is foreign" \
    "$(json_array "$OUT" resolved)" ""
check "case 20: the differently spelled host is reported" \
    "$(json_array "$OUT" skipped | grep -c 'box.example.com#1')" "1"
check "case 20: the foreign marker stamped nothing" "$(fix_of "$C20L" 1)" ""
R20B="$(new_repo c20b)"
"$BIN" add --skill boxed --machine "$H" --db "$C20L" >/dev/null
printf y >"$R20B/f"
git -C "$R20B" add f
git -C "$R20B" commit -q -m "skills: fix the box row" -m "Skill-log-Fix: $H#2"
OUT="$(cd "$R20B" && "$BIN" resolve-merged --db "$C20L" --json 2>/dev/null)"
check "case 20: the exact spelling resolves" \
    "$(json_array "$OUT" resolved)" "$H#2"

# --- case 21: a marker the last-trailer-block rule hides is reported ------
say "parity: case 21 — a marker hidden by a later trailer block is reported"
R21="$(new_repo c21)"
DB21="$DBT/c21.db"
"$BIN" add --skill hidden-marker --db "$DB21" >/dev/null
printf y >"$R21/f"
git -C "$R21" add f
git -C "$R21" commit -q -m "skills: fix one thing" \
    -m "Skill-log-Fix: $H#1" -m "Co-authored-by: someone <s@example.com>"
run_in "$R21" resolve-merged --db "$DB21"
check_contains "case 21: a hidden marker is reported" "$ERR" "ignored marker"
check_contains "case 21: the hidden note says why" "$ERR" \
    "not in the commit's last trailer block"
check "case 21: the hidden marker stamped nothing" "$(fix_of "$DB21" 1)" ""
OUT="$(cd "$R21" && "$BIN" resolve-merged --db "$DB21" --json)"
check "case 21: the JSON names the ignored marker" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["ignored"]))')" "1"
OUT="$(cd "$R21" && "$BIN" resolve-merged --db "$DB21" --quiet 2>&1)"
check "case 21: --quiet prints nothing for a hidden marker" "$OUT" ""

# --- case 22: the newest marker wins, and --since cannot smuggle an option
say "parity: case 22 — the newest marker wins, and --since refuses an option"
R22="$(new_repo c22)"
DB22="$DBT/c22.db"
"$BIN" add --skill named-twice --db "$DB22" >/dev/null
printf a >"$R22/f"
git -C "$R22" add f
git -C "$R22" commit -q -m "skills: the first fix" -m "Skill-log-Fix: $H#1"
OLDER="$(git -C "$R22" rev-parse HEAD)"
printf b >"$R22/f"
git -C "$R22" add f
git -C "$R22" commit -q -m "skills: the later fix" -m "Skill-log-Fix: $H#1"
NEWER="$(git -C "$R22" rev-parse HEAD)"
check "case 22: the two fix commits are distinct" \
    "$([ "$NEWER" != "$OLDER" ] && echo distinct || echo same)" "distinct"
(cd "$R22" && "$BIN" resolve-merged --db "$DB22" --json >/dev/null 2>&1)
check "case 22: the row named twice is stamped by the newer commit" \
    "$(fix_of "$DB22" 1)" "$NEWER"
run_in "$R22" resolve-merged --since=--output=/tmp/opencode/x --db "$DB22"
check "case 22: an option-shaped --since exits 2" "$STATUS" "2"
check_contains "case 22: an option-shaped --since says what it needs" "$ERR" \
    "--since needs a revision"

# --- case 23: the hook contract -------------------------------------------
say "parity: case 23 — the hook is idempotent, keeps a foreign hook, and cannot break a pull"
R23="$(new_repo c23)"
printf base >"$R23/base"
git -C "$R23" add base
git -C "$R23" commit -q -m base
HOOK23="$R23/.git/hooks/post-merge"
run setup --repo "$R23"
check "case 23: setup installs the hook" "$STATUS" "0"
if [ -x "$HOOK23" ]; then
    pass "case 23: the hook is executable"
else
    fail "case 23: the hook is executable"
fi
FIRST23="$(md5sum <"$HOOK23" | cut -d' ' -f1)"
run setup --repo "$R23"
check "case 23: re-running the installer leaves the hook identical" \
    "$(md5sum <"$HOOK23" | cut -d' ' -f1)" "$FIRST23"
if find "$R23/.git/hooks" -maxdepth 1 -name 'post-merge.tmp.*' | grep -q .; then
    fail "case 23: the installer left a temp file behind"
else
    pass "case 23: the installer left no temp file"
fi
rm -f "$HOOK23"
printf '#!/bin/sh\necho foreign hook\n' >"$HOOK23"
chmod +x "$HOOK23"
run setup --repo "$R23"
check "case 23: a foreign hook is refused" "$STATUS" "1"
check_contains "case 23: the refusal names the ownership marker" "$ERR" \
    "ownership marker"
check "case 23: the foreign hook is preserved byte-for-byte" \
    "$(grep -c 'echo foreign hook' "$HOOK23")" "1"
R23B="$(new_repo c23b)"
printf base >"$R23B/base"
git -C "$R23B" add base
git -C "$R23B" commit -q -m base
run setup --repo "$R23B"
check "case 23: setup installs the owned hook" "$STATUS" "0"
mkdir -p "$S/empty-path"
ln -sf "$(command -v git)" "$S/empty-path/git"
git -C "$R23B" checkout -q -b nobin
printf a >"$R23B/f"
git -C "$R23B" add f
git -C "$R23B" commit -q -m "skills: marker with no binary" -m "Skill-log-Fix: box#1"
git -C "$R23B" checkout -q main
if env HOME="$HOME" XDG_STATE_HOME="$S/c23-state" PATH="$S/empty-path" \
    git -C "$R23B" merge -q --ff-only nobin >"$S/c23-pull.out" \
    2>"$S/c23-pull.err"; then
    pass "case 23: a missing skill-log did not break the pull"
else
    fail "case 23: a missing skill-log broke the pull"
fi
check "case 23: the pull with no CLI says nothing" \
    "$(cat "$S/c23-pull.out" "$S/c23-pull.err")" ""
check "case 23: the hook with no CLI created no store" \
    "$([ -e "$S/c23-state/skill-log/skills.db" ] \
        && echo created || echo absent)" "absent"
cat >"$S/empty-path/skill-log" <<'STUB'
#!/bin/sh
echo "skill-log: error: argument command: invalid choice: 'resolve-merged'" >&2
exit 2
STUB
chmod +x "$S/empty-path/skill-log"
git -C "$R23B" checkout -q -b oldbin
printf b >"$R23B/f"
git -C "$R23B" add f
git -C "$R23B" commit -q -m "skills: marker with an old binary" -m "Skill-log-Fix: box#1"
git -C "$R23B" checkout -q main
if env -u XDG_STATE_HOME HOME="$HOME" PATH="$S/empty-path" \
    git -C "$R23B" merge -q --ff-only oldbin >"$S/c23-pull2.out" \
    2>"$S/c23-pull2.err"; then
    pass "case 23: an old skill-log did not break the pull"
else
    fail "case 23: an old skill-log broke the pull"
fi
check_absent "case 23: the failing CLI leaked nothing into the pull" \
    "$(cat "$S/c23-pull2.err")" "invalid choice"
check "case 23: the pull with an old CLI says nothing" \
    "$(cat "$S/c23-pull2.out")" ""
mkdir -p "$S/not-a-repo"
run setup --repo "$S/not-a-repo"
check "case 23: a non-git checkout exits 0" "$STATUS" "0"
check_contains "case 23: the non-git checkout skips with a named reason" "$OUT" \
    "not a git checkout"

# --- case 24: report writes the repo report artifact ----------------------
say "parity: case 24 — report writes the repo report file, validated at authoring time"
R24="$(new_repo c24)"
DB24="$DBT/c24.db"
"$BIN" add --skill report-one --db "$DB24" >/dev/null
"$BIN" add --skill report-two --db "$DB24" >/dev/null
"$BIN" add --skill report-done --db "$DB24" >/dev/null
"$BIN" resolve --id 3 --fix deadbeef --db "$DB24" >/dev/null
"$BIN" add --skill report-threaded --session ses_c24 --db "$DB24" >/dev/null
mkdir -p "$R24/.skill-log/reports"
: >"$R24/.skill-log/reports/.keep"
git -C "$R24" add -A
git -C "$R24" commit -q -m "the report directory"
REPORT24="$R24/.skill-log/reports/report.md"
run_in "$R24" report --id 1 --slug report --db "$DB24"
check "case 24: report names the file it wrote" "$OUT" \
    "reported 1 marker in .skill-log/reports/report.md"
check "case 24: the report names the marker, not the local id" \
    "$(cat "$REPORT24")" "$H#1"
run_in "$R24" report --id 2 --id 3 --slug report --db "$DB24"
check "case 24: re-running unions, and an already-resolved row stays out" \
    "$(tr '\n' ',' <"$REPORT24")" "$H#1,$H#2,"
run_in "$R24" report --run ses_c24 --slug report --db "$DB24"
check "case 24: a run's rows arrive" \
    "$(tr '\n' ',' <"$REPORT24")" "$H#1,$H#2,$H#4,"
run_in "$R24" report --id 99 --db "$DB24"
check "case 24: an unknown id exits 1" "$STATUS" "1"
check_contains "case 24: an unknown id is refused" "$ERR" "no invocation 99"
check_one_line "case 24: the refusal is one line" "$ERR"
run_in "$R24" report --check --slug report --db "$DB24"
check "case 24: a well-formed report passes --check" "$STATUS" "0"
printf 'not-a-marker\n' >>"$REPORT24"
run_in "$R24" report --check --slug report --db "$DB24"
check "case 24: a malformed line fails --check" "$STATUS" "1"
check_contains "case 24: the malformed line is named" "$ERR" \
    "not a marker (machine#id): not-a-marker"
run_in "$R24" report --check --slug absent --db "$DB24"
check "case 24: a branch with no report is not an error" "$STATUS" "0"
run_in "$R24" report --id 1 --slug dry --db "$DB24" --dry-run
if [ -e "$R24/.skill-log/reports/dry.md" ]; then
    fail "case 24: a dry run created the report file"
else
    pass "case 24: a dry run created no report file"
fi

# --- case 25: a repo with the report directory resolves from the report ---
say "parity: case 25 — the report file, not the trailer, drives resolution where it exists"
R25="$(new_repo c25)"
mkdir -p "$R25/.skill-log/reports"
: >"$R25/.skill-log/reports/.keep"
git -C "$R25" add -A
git -C "$R25" commit -q -m base
DB25="$DBT/c25.db"
ID25="$("$BIN" add --skill c25-by-file --db "$DB25" --json | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
ID25T="$("$BIN" add --skill c25-by-trailer --db "$DB25" --json | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
run_in "$R25" report --id "$ID25" --slug report --db "$DB25"
git -C "$R25" checkout -q -b report-branch
git -C "$R25" add -A
git -C "$R25" commit -q -m "skills: fix by report" -m "Skill-log-Fix: $H#$ID25T"
FIX25="$(git -C "$R25" rev-parse HEAD)"
git -C "$R25" checkout -q main
git -C "$R25" merge -q --ff-only report-branch >/dev/null 2>&1
run_in "$R25" resolve-merged --db "$DB25" --json
check "case 25: the report file's commit stamps its row" \
    "$(fix_of "$DB25" "$ID25")" "$FIX25"
check "case 25: a trailer is not read in artifact mode" \
    "$(fix_of "$DB25" "$ID25T")" ""
check_contains "case 25: the ignored trailer is reported" "$ERR" \
    "resolves from .skill-log/reports"
run_in "$R25" resolve-merged --db "$DB25" --json
check "case 25: a second scan stamps nothing" "$(json_array "$OUT" resolved)" ""
check "case 25: a second scan names the rows it left alone" \
    "$(json_array "$OUT" unchanged)" "$H#$ID25"
DB25M="$DBT/c25-manual.db"
IDM="$("$BIN" add --skill c25-manual --db "$DB25M" --json | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
printf '%s#%s\n' "$H" "$IDM" >"$R25/.skill-log/reports/manual.md"
git -C "$R25" add -A
git -C "$R25" commit -q -m "report two"
OUT="$(cd "$R25" && "$BIN" resolve-merged --db "$DB25M" --json)"
check "case 25: a full scan resolves the report file's row" \
    "$(json_array "$OUT" resolved)" "$H#$IDM"

# =========================================================================
# =========================================================================

# --- case 26: the store matrix, per verb's policy -------------------------
say "parity: case 26 — the store matrix, per verb's policy"
MATRIX="$S/matrix"
mkdir -p "$MATRIX"
sqlite3 "$MATRIX/empty.db" <<'SQL'
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
printf 'not a sqlite file at all' >"$MATRIX/damaged.db"
sqlite3 "$MATRIX/foreign.db" 'CREATE TABLE something (x)'
mkolderdb "$MATRIX/older.db"
cp "$MATRIX/empty.db" "$MATRIX/newer.db"
sqlite3 "$MATRIX/newer.db" 'PRAGMA user_version=99'

run add --skill matrix --db "$MATRIX/absent.db"
check "case 26: add creates an absent store" "$STATUS" "0"
check "case 26: the created store holds the row" \
    "$(count_rows "$MATRIX/absent.db")" "1"
run show --db "$MATRIX/absent2.db"
check "case 26: show on an absent store exits 0" "$STATUS" "0"
check "case 26: show on an absent store is the empty message" "$OUT" \
    "no invocations logged yet"
run stats --db "$MATRIX/absent2.db"
check "case 26: stats on an absent store exits 0" "$STATUS" "0"
check "case 26: stats on an absent store is the empty message" "$OUT" \
    "no invocations logged yet"
run show --db "$MATRIX/empty.db"
check "case 26: show on an empty store exits 0" "$STATUS" "0"
check "case 26: show on an empty store is the empty message" "$OUT" \
    "no invocations logged yet"
run stats --db "$MATRIX/empty.db"
check "case 26: stats on an empty store exits 0" "$STATUS" "0"
check "case 26: stats on an empty store is the empty message" "$OUT" \
    "no invocations logged yet"
run add --skill matrix --db "$MATRIX/empty.db"
check "case 26: add fills an empty store" "$STATUS" "0"
check "case 26: the filled store holds the row" \
    "$(count_rows "$MATRIX/empty.db")" "1"
R26="$(new_repo c26)"
R26T="$(new_repo c26t)"
commit_trailers "$R26" "skills: fix a row" "Skill-log-Fix: $H#1"
commit_trailers "$R26T" "skills: fix a row" "Skill-log-Fix: $H#1"
run_in "$R26" report --id 1 --slug m --db "$MATRIX/absent3.db"
check "case 26: report on an absent store exits 1" "$STATUS" "1"
check_contains "case 26: report on an absent store is named" "$ERR" \
    "no store at"
run resolve --id 1 --fix abc --db "$MATRIX/absent3.db"
check "case 26: resolve on an absent store exits 1" "$STATUS" "1"
check_contains "case 26: resolve on an absent store is named" "$ERR" \
    "no store at"
sqlite3 "$MATRIX/empty2.db" <<'SQL'
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
run resolve --id 1 --fix abc --db "$MATRIX/empty2.db"
check "case 26: resolve on an empty store exits 1" "$STATUS" "1"
check_contains "case 26: resolve on an empty store names the missing id" \
    "$ERR" "no invocation 1"
check_one_line "case 26: the empty store's refusal is one line" "$ERR"
run_in "$R26T" resolve-merged --db "$MATRIX/absent4.db"
check "case 26: resolve-merged on an absent store exits 0" "$STATUS" "0"
check "case 26: resolve-merged on an absent store writes no store" \
    "$([ -e "$MATRIX/absent4.db" ] && echo created || echo absent)" "absent"
run setup --repo "$R26" --check --db "$MATRIX/absent5.db"
check "case 26: setup --check on an absent store exits 1" "$STATUS" "1"
check_contains "case 26: setup --check names the missing store" "$ERR" \
    "no store at"
for kind in damaged foreign older newer; do
    for verb in add show stats resolve; do
        case "$verb" in
            add) args="add --skill x" ;;
            resolve) args="resolve --id 1 --fix abc" ;;
            *) args="$verb" ;;
        esac
        # shellcheck disable=SC2086  # the argument list is deliberately word-split
        run $args --db "$MATRIX/$kind.db"
        check "case 26: $verb refuses a $kind store" "$STATUS" "1"
        check_contains "case 26: $verb names the $kind store" "$ERR" \
            "$kind store"
        check_one_line "case 26: $verb's $kind refusal is one line" "$ERR"
    done
    run_in "$R26" report --id 1 --slug m --db "$MATRIX/$kind.db"
    check "case 26: report refuses a $kind store" "$STATUS" "1"
    check_contains "case 26: report names the $kind store" "$ERR" \
        "$kind store"
    run_in "$R26T" resolve-merged --db "$MATRIX/$kind.db"
    check "case 26: resolve-merged refuses a $kind store" "$STATUS" "1"
    check_contains "case 26: resolve-merged names the $kind store" "$ERR" \
        "$kind store"
    run setup --repo "$R26" --db "$MATRIX/$kind.db"
    check "case 26: setup refuses a $kind store" "$STATUS" "1"
    check_contains "case 26: setup names the $kind store" "$ERR" "$kind store"
done
for kind in damaged foreign older newer; do
    BEFORE_SUM="$(md5sum <"$MATRIX/$kind.db")"
    run add --skill x --db "$MATRIX/$kind.db"
    check "case 26: the $kind store is byte-identical after a refusal" \
        "$(md5sum <"$MATRIX/$kind.db")" "$BEFORE_SUM"
done

# --- case 27: report --check without a selector ---------------------------
say "parity: case 27 — report --check needs no selector"
R27="$(new_repo c27)"
mkdir -p "$R27/.skill-log/reports"
: >"$R27/.skill-log/reports/.keep"
git -C "$R27" add -A
git -C "$R27" commit -q -m "the report directory"
run_in "$R27" report --check --db "$DBT/c27.db"
check "case 27: report --check without a selector exits 0" "$STATUS" "0"
check_contains "case 27: report --check names the file it checked" "$OUT" \
    ".skill-log/reports/"
check "case 27: report --check wrote no report" \
    "$(find "$R27/.skill-log/reports" -name '*.md' | wc -l | tr -d ' ')" "0"
OUT="$(cd "$R27" && "$BIN" report --check --json --db "$DBT/c27.db")"
check "case 27: report --check --json exits 0" "$?" "0"
check "case 27: the check's json carries the path" \
    "$(json_field "$OUT" path)" ".skill-log/reports/main.md"

# --- case 28: uncommitted report edits resolve nothing --------------------
say "parity: case 28 — uncommitted report edits resolve nothing"
R28="$(new_repo c28)"
mkdir -p "$R28/.skill-log/reports"
: >"$R28/.skill-log/reports/.keep"
git -C "$R28" add -A
git -C "$R28" commit -q -m "the report directory"
DB28="$DBT/c28.db"
"$BIN" add --skill reported --db "$DB28" >/dev/null
printf '%s#1\n' "$H" >"$R28/.skill-log/reports/fix.md"
run_in "$R28" resolve-merged --db "$DB28" --json
check "case 28: an uncommitted report resolves nothing" \
    "$(fix_of "$DB28" 1)" ""
check "case 28: an uncommitted report names no resolved row" \
    "$(json_array "$OUT" resolved)" ""
git -C "$R28" add -A
git -C "$R28" commit -q -m "the report"
run_in "$R28" resolve-merged --db "$DB28" --json
check "case 28: the committed report resolves the row" \
    "$(fix_of "$DB28" 1)" "$(git -C "$R28" rev-parse HEAD)"
"$BIN" add --skill not-reported --db "$DB28" >/dev/null
printf '%s#1\n%s#2\n' "$H" "$H" >"$R28/.skill-log/reports/fix.md"
run_in "$R28" resolve-merged --db "$DB28" --json
check "case 28: an uncommitted edit adds no row" "$(fix_of "$DB28" 2)" ""

# --- case 29: the time guard across differing writer offsets --------------
say "parity: case 29 — the time guard compares instants, not offset strings"
R29="$(new_repo c29)"
DB29="$DBT/c29.db"
"$BIN" add --skill offset-row --db "$DB29" >/dev/null
sqlite3 "$DB29" "UPDATE invocations SET ts = '2026-06-01T12:00:00+02:00' WHERE id = 1"
GIT_COMMITTER_DATE="2026-06-01T10:00:00+0000" \
GIT_AUTHOR_DATE="2026-06-01T10:00:00+0000" \
    git -C "$R29" commit -q --allow-empty -m "skills: fix the row" \
    -m "Skill-log-Fix: $H#1"
run_in "$R29" resolve-merged --db "$DB29"
check "case 29: the same instant in two offsets is not 'logged after'" \
    "$(fix_of "$DB29" 1)" "$(git -C "$R29" rev-parse HEAD)"
check "case 29: the row's stamp is the offset it was written with" \
    "$(sqlite3 "$DB29" 'SELECT ts FROM invocations WHERE id = 1')" \
    "2026-06-01T12:00:00+02:00"
sqlite3 "$DB29" "UPDATE invocations SET ts = '2026-06-01T12:00:01+02:00' WHERE id = 1"
R29B="$(new_repo c29b)"
printf base >"$R29B/base"
git -C "$R29B" add base
git -C "$R29B" commit -q -m base
GIT_COMMITTER_DATE="2026-06-01T10:00:00+0000" \
GIT_AUTHOR_DATE="2026-06-01T10:00:00+0000" \
    git -C "$R29B" commit -q --allow-empty -m "skills: fix the row again" \
    -m "Skill-log-Fix: $H#1"
run_in "$R29B" resolve-merged --db "$DB29"
check_contains "case 29: a later instant is skipped with its reason" "$ERR" \
    "skipped: logged_after_commit"

# --- case 30: the deliberate non-idempotency of add -----------------------
say "parity: case 30 — add records occurrences, it does not deduplicate"
C30="$DBT/c30.db"
"$BIN" add --skill twice --db "$C30" >/dev/null
"$BIN" add --skill twice --db "$C30" >/dev/null
check "case 30: two identical calls produce two rows" "$(count_rows "$C30")" "2"
check "case 30: the two rows carry different ids" \
    "$(sqlite3 "$C30" 'SELECT COUNT(DISTINCT id) FROM invocations')" "2"

# --- case 31: the repo and worktree, inside, outside and across a link ----
say "parity: case 31 — the repo and worktree, inside, outside and across a link"
R31="$(new_repo c31)"
git -C "$R31" remote add origin "https://user:secret@example.com/owner/thing.git"
git -C "$R31" worktree add -q -b linked "$S/repos/c31-linked" 2>/dev/null
mkdir -p "$S/outside"
cd "$R31" || exit 1
OUT="$("$BIN" add --skill inside --dry-run --json)"
check "case 31: inside a checkout the repo is the origin's basename" \
    "$(json_field "$OUT" repo)" "thing"
check "case 31: inside a checkout the worktree is the toplevel" \
    "$(json_field "$OUT" worktree)" "$R31"
check "case 31: the credentials never reach the row" \
    "$(printf '%s' "$OUT" | grep -c 'secret')" "0"
cd "$S/repos/c31-linked" || exit 1
OUT="$("$BIN" add --skill linked --dry-run --json)"
check "case 31: a linked worktree has its own toplevel" \
    "$(json_field "$OUT" worktree)" "$S/repos/c31-linked"
check "case 31: a linked worktree has the same repo" \
    "$(json_field "$OUT" repo)" "thing"
cd "$S/outside" || exit 1
OUT="$("$BIN" add --skill outside --dry-run --json)"
check "case 31: outside a checkout the repo is blank" \
    "$(json_field "$OUT" repo)" ""
check "case 31: outside a checkout the worktree is blank" \
    "$(json_field "$OUT" worktree)" ""

# --- case 32: the machine names the marker --------------------------------
say "parity: case 32 — a marker is machine#id, and the machine is the hostname"
C32="$DBT/c32.db"
OUT="$("$BIN" add --skill marker --db "$C32")"
check "case 32: add prints the marker" "$OUT" "$H#1"
OUT="$("$BIN" show --db "$C32" --json)"
check "case 32: show --json carries the marker" \
    "$(json_field "$OUT" marker)" "$H#1"
check "case 32: the machine is the hostname" \
    "$(json_field "$OUT" machine)" "$H"

# --- case 33: the sandbox guard refuses the real home ---------------------
say "parity: case 33 — the sandbox guard refuses the real home"
if sandbox_ok "$REAL_HOME/inside" "$REAL_HOME/inside/home"; then
    fail "case 33: a sandbox inside the real home is refused"
else
    pass "case 33: a sandbox inside the real home is refused"
fi
if sandbox_ok "$S" "$S/../outside"; then
    fail "case 33: a home outside the sandbox is refused"
else
    pass "case 33: a home outside the sandbox is refused"
fi
check "case 33: the sandbox the suite runs in is accepted" \
    "$(sandbox_ok "$S" "$S/home" && echo accepted || echo refused)" "accepted"
REAL_DB="$REAL_HOME/.local/state/skill-log/skills.db"
REAL_SUM="$(md5sum <"$REAL_DB" 2>/dev/null || printf 'absent')"
run add --skill must-not-reach-the-real-store
REAL_SUM_AFTER="$(md5sum <"$REAL_DB" 2>/dev/null || printf 'absent')"
check "case 33: the real store's bytes did not move" \
    "$REAL_SUM_AFTER" "$REAL_SUM"
check "case 33: the row went to the sandbox's store, not the real one" \
    "$(sqlite3 "$HOME/.local/state/skill-log/skills.db" \
        "SELECT COUNT(*) FROM invocations WHERE skill = 'must-not-reach-the-real-store'" \
        2>/dev/null || printf 0)" "1"

# ----------------------------------------------------------------- report

printf '\n'
if [ "$SKIPPED" -gt 0 ]; then
    printf 'parity.sh: %d reference case(s) skipped as out of scope\n' "$SKIPPED"
fi
OUT="$(SKILL_LOG_NOW="2020-01-02T03:04:05+00:00" \
    "$BIN" add --skill clock-probe --dry-run --json 2>"$S/stderr")"
STATUS=$?
check "the clock case exits 0" "$STATUS" "0"
check "case 34: SKILL_LOG_NOW pins the writer's stamp" \
    "$(json_field "$OUT" ts)" "2020-01-02T03:04:05+00:00"
check_absent "the clock case reports no error" "$(cat "$S/stderr")" "skill-log:"
tally
