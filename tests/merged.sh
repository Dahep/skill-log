#!/usr/bin/env bash
# The resolve-merged test: resolve the rows a pull landed.
#
#   tests/merged.sh
#
# The hook's entry point, exercised as a process: commit trailers, a
# report directory, a bounded range, a reused id, a hidden marker, and
# the failures that must stay failures. The store is built through `add`;
# `sqlite3` only inspects it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-merged}"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools sqlite3 python3 git

if [ ! -x "$BIN" ]; then
    printf 'merged.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" "$SCRATCH/state"

export HOME="$SCRATCH/home"
export XDG_STATE_HOME="$SCRATCH/state"
unset SKILL_LOG_DB SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME

run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# new_repo <name>: an empty git repository under the scratch root.
new_repo() {
    local repo="$SCRATCH/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf '%s' "$repo"
}

# commit_file <repo> <marker-block>: one commit for a new file content.
commit_file() {
    local repo="$1" trailer="$2" n
    n="$(date +%s%N)"
    printf '%s' "$n" >"$repo/file"
    git -C "$repo" add file
    git -C "$repo" commit -q -m "change $n" -m "$trailer"
}

# ----------------------------------------------------------------- trailer

REPO="$(new_repo trailer)"
DB="$SCRATCH/trailer.db"

"$BIN" add --skill alpha --machine boxA --db "$DB" >/dev/null
"$BIN" add --skill beta --machine boxA --db "$DB" >/dev/null
commit_file "$REPO" "Skill-log-Fix: boxA#1, boxA#2"
FIRST="$(git -C "$REPO" rev-parse HEAD)"

(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --json >"$SCRATCH/one.json" 2>"$SCRATCH/one.err"
)
check "both named rows are stamped" \
    "$(json_array "$(cat "$SCRATCH/one.json")" resolved)" "boxA#1,boxA#2"
check "the stamp is the fix commit" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 1')" "$FIRST"
check "the second row carries the same commit" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 2')" "$FIRST"
check "the timestamp is ISO 8601 with an offset" \
    "$(sqlite3 "$DB" "select resolved_at from invocations where id = 1" \
        | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"
check "the scan is silent on stderr" "$(cat "$SCRATCH/one.err")" ""

# Idempotent: the hook runs after every pull for free.
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --json >"$SCRATCH/two.json" 2>"$SCRATCH/two.err"
)
check "a second scan stamps nothing" \
    "$(json_array "$(cat "$SCRATCH/two.json")" resolved)" ""
check "a second scan names the rows it left alone" \
    "$(json_array "$(cat "$SCRATCH/two.json")" unchanged)" "boxA#1,boxA#2"
check "a second scan prints no note" "$(cat "$SCRATCH/two.err")" ""
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --quiet >"$SCRATCH/quiet.out" 2>"$SCRATCH/quiet.err"
)
check "--quiet prints nothing" "$(cat "$SCRATCH/quiet.out")$(cat "$SCRATCH/quiet.err")" ""

# ------------------------------------------------------------- reused ids

# A row logged after the named commit is an id reused by a rebuilt log.
commit_file "$REPO" "Skill-log-Fix: boxA#3"
sleep 1
"$BIN" add --skill logged-later --machine boxA --db "$DB" >/dev/null
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" >/dev/null 2>"$SCRATCH/later.err"
)
check_contains "a later row is skipped with its reason" \
    "$(cat "$SCRATCH/later.err")" "boxA#3 skipped: logged_after_commit"
check "the guarded row stays unresolved" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 3')" ""

# The contract's skip tokens, not prose, reach both answers.
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --dry-run --json >"$SCRATCH/tokens.json" 2>/dev/null
)
check "the skip reason in JSON is the contract token" \
    "$(printf '%s' "$(cat "$SCRATCH/tokens.json")" \
        | python3 -c 'import json,sys; print(",".join(sorted(
            s["reason"] for s in json.loads(sys.stdin.read())["skipped"])))')" \
    "logged_after_commit"

# ---------------------------------------------- unknown, malformed, hidden

commit_file "$REPO" "Skill-log-Fix: boxA#99, <id>, 7"
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --json >"$SCRATCH/bad.json" 2>"$SCRATCH/bad.err"
)
check_contains "an unknown id is reported by name" \
    "$(cat "$SCRATCH/bad.err")" "boxA#99 skipped: unknown_id"
check_contains "a placeholder is reported" \
    "$(cat "$SCRATCH/bad.err")" "not a Skill-log-Fix marker (machine#id): <id>"
check_contains "a bare id is reported" \
    "$(cat "$SCRATCH/bad.err")" "not a Skill-log-Fix marker (machine#id): 7"
check "a malformed marker stamps nothing" \
    "$(sqlite3 "$DB" "select count(*) from invocations where fix <> ''")" "2"
check "the JSON names the unknown row" \
    "$(json_array "$(cat "$SCRATCH/bad.json")" skipped | grep -c 'boxA#99')" "1"
check "the unknown id's reason is the contract token" \
    "$(printf '%s' "$(cat "$SCRATCH/bad.json")" \
        | python3 -c 'import json,sys; print(next(
            s["reason"] for s in json.loads(sys.stdin.read())["skipped"]
            if s["row"] == "boxA#99"))')" \
    "unknown_id"

# ----------------------------------------------------------- foreign markers

# A marker naming another machine is foreign: reported, never stamped.
commit_file "$REPO" "Skill-log-Fix: otherbox#7"
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --json >"$SCRATCH/foreign.json" 2>"$SCRATCH/foreign.err"
)
check_contains "a foreign marker is reported by name" \
    "$(cat "$SCRATCH/foreign.err")" "otherbox#7 skipped: foreign"
check "the foreign marker stamps nothing" \
    "$(sqlite3 "$DB" "select count(*) from invocations where fix <> ''")" "2"
check "the foreign marker's reason is the contract token" \
    "$(printf '%s' "$(cat "$SCRATCH/foreign.json")" \
        | python3 -c 'import json,sys; print(next(
            s["row"] + "=" + s["reason"]
            for s in json.loads(sys.stdin.read())["skipped"]
            if s["row"] == "otherbox#7"))')" \
    "otherbox#7=foreign"
check "a foreign marker is never stamped in the answer" \
    "$(json_array "$(cat "$SCRATCH/foreign.json")" resolved)" ""

"$BIN" add --skill hidden --machine boxA --db "$DB" >/dev/null
n="$(date +%s%N)"
printf '%s' "$n" >"$REPO/file"
git -C "$REPO" add file
# The shape a multi-author squash leaves: the marker block, then a later
# trailer block that hides it from git's trailer parser.
git -C "$REPO" commit -q \
    -m "skills: name a hidden row" \
    -m "Skill-log-Fix: boxA#4" \
    -m "Co-authored-by: someone <s@example.com>"
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --json >"$SCRATCH/hidden.json" 2>"$SCRATCH/hidden.err"
)
check_contains "a hidden marker is reported" \
    "$(cat "$SCRATCH/hidden.err")" "ignored marker"
check_contains "the hidden note says why" \
    "$(cat "$SCRATCH/hidden.err")" "not in the commit's last trailer block"
check "the hidden marker stamped nothing" \
    "$(sqlite3 "$DB" 'select fix from invocations where id = 4')" ""
check "the JSON names one ignored marker" \
    "$(printf '%s' "$(cat "$SCRATCH/hidden.json")" \
        | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["ignored"]))')" "1"
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$DB" --quiet >"$SCRATCH/hq.out" 2>"$SCRATCH/hq.err"
)
check "--quiet hides the ignored marker" \
    "$(cat "$SCRATCH/hq.out")$(cat "$SCRATCH/hq.err")" ""

# ----------------------------------------------------------- newest wins

REPO2="$(new_repo newest)"
DB2="$SCRATCH/newest.db"
"$BIN" add --skill named-twice --machine boxA --db "$DB2" >/dev/null
commit_file "$REPO2" "Skill-log-Fix: boxA#1"
OLDER="$(git -C "$REPO2" rev-parse HEAD)"
commit_file "$REPO2" "Skill-log-Fix: boxA#1"
NEWER="$(git -C "$REPO2" rev-parse HEAD)"
(
    cd "$REPO2" || exit 1
    "$BIN" resolve-merged --db "$DB2" --json >"$SCRATCH/newest.json"
)
check "the newest marker for a row wins" \
    "$(sqlite3 "$DB2" 'select fix from invocations where id = 1')" "$NEWER"
check "the older marker is not the stamp" \
    "$(sqlite3 "$DB2" "select fix <> '$OLDER' from invocations where id = 1")" "1"
check "the row appears once in the answer" \
    "$(json_array "$(cat "$SCRATCH/newest.json")" resolved)" "boxA#1"

# --------------------------------------------------- restamp on a new commit

# An amended fix supersedes an earlier one: a row already stamped with a
# different commit is restamped, and the stamp moves. Idempotency is a
# second scan of the *same* commit, not a freeze on the first fix.
REPO7="$(new_repo restamp)"
DB7="$SCRATCH/restamp.db"
"$BIN" add --skill amended --machine boxA --db "$DB7" >/dev/null
commit_file "$REPO7" "Skill-log-Fix: boxA#1"
OLDER_FIX="$(git -C "$REPO7" rev-parse HEAD)"
(
    cd "$REPO7" || exit 1
    "$BIN" resolve-merged --db "$DB7" --json >"$SCRATCH/restamp1.json"
)
check "the first fix stamps the row" \
    "$(sqlite3 "$DB7" 'select fix from invocations where id = 1')" "$OLDER_FIX"
RESOLVED_ONE="$(sqlite3 "$DB7" 'select resolved_at from invocations where id = 1')"

# A newer commit naming the same row: the amended fix supersedes.
sleep 1
commit_file "$REPO7" "Skill-log-Fix: boxA#1"
NEWER_FIX="$(git -C "$REPO7" rev-parse HEAD)"
(
    cd "$REPO7" || exit 1
    "$BIN" resolve-merged --db "$DB7" --json >"$SCRATCH/restamp2.json" 2>"$SCRATCH/restamp2.err"
)
check "a newer commit restamps the row" \
    "$(sqlite3 "$DB7" 'select fix from invocations where id = 1')" "$NEWER_FIX"
check "the restamped row is reported as resolved" \
    "$(json_array "$(cat "$SCRATCH/restamp2.json")" resolved)" "boxA#1"
check "resolved_at moves to the restamp" \
    "$([ "$(sqlite3 "$DB7" 'select resolved_at from invocations where id = 1')" \
        != "$RESOLVED_ONE" ] && echo moved || echo frozen)" "moved"

# A same-commit row is unchanged; a re-scan of the newer range is idempotent.
(
    cd "$REPO7" || exit 1
    "$BIN" resolve-merged --since "$OLDER_FIX" --db "$DB7" --json >"$SCRATCH/restamp3.json"
)
check "a same-commit row is unchanged, not restamped" \
    "$(json_array "$(cat "$SCRATCH/restamp3.json")" unchanged)" "boxA#1"
check "a re-scan of the newer range stamps nothing" \
    "$(json_array "$(cat "$SCRATCH/restamp3.json")" resolved)" ""
check "a re-scan leaves the stamp alone" \
    "$(sqlite3 "$DB7" 'select fix from invocations where id = 1')" "$NEWER_FIX"

# ------------------------------------------------------------ --since

REPO3="$(new_repo since)"
DB3="$SCRATCH/since.db"
"$BIN" add --skill old --machine boxA --db "$DB3" >/dev/null
commit_file "$REPO3" "Skill-log-Fix: boxA#1"
BASE="$(git -C "$REPO3" rev-parse HEAD)"
"$BIN" add --skill new --machine boxA --db "$DB3" >/dev/null
commit_file "$REPO3" "Skill-log-Fix: boxA#2"
(
    cd "$REPO3" || exit 1
    "$BIN" resolve-merged --since "$BASE" --db "$DB3" --json >"$SCRATCH/since.json"
)
check "--since only reads what came after it" \
    "$(json_array "$(cat "$SCRATCH/since.json")" resolved)" "boxA#2"
check "the marker before --since is left alone" \
    "$(sqlite3 "$DB3" 'select fix from invocations where id = 1')" ""

# A range git cannot resolve is a quiet full scan, not a failed pull.
(
    cd "$REPO3" || exit 1
    "$BIN" resolve-merged --since no-such-revision --db "$DB3" \
        >"$SCRATCH/fallback.out" 2>"$SCRATCH/fallback.err"
)
check "an unresolvable --since still exits 0" "$?" "0"
check "the fallback is quiet" "$(cat "$SCRATCH/fallback.err")" ""
check "the fallback scans the full history" \
    "$(sqlite3 "$DB3" "select fix <> '' from invocations where id = 1")" "1"

# An option-shaped --since would reach git as an option: refuse it.
(
    cd "$REPO3" || exit 1
    "$BIN" resolve-merged --since=--output=/tmp/opencode/x --db "$DB3" \
        >/dev/null 2>"$SCRATCH/bound.err"
)
STATUS=$?
check "an option-shaped --since exits 2" "$STATUS" "2"
check_contains "an option-shaped --since says what it needs" \
    "$(cat "$SCRATCH/bound.err")" "--since needs a revision"

# -------------------------------------------------------------- dry run

REPO4="$(new_repo dry)"
DB4="$SCRATCH/dry.db"
"$BIN" add --skill dry-run --machine boxA --db "$DB4" >/dev/null
commit_file "$REPO4" "Skill-log-Fix: boxA#1"
(
    cd "$REPO4" || exit 1
    "$BIN" resolve-merged --db "$DB4" --dry-run --json >"$SCRATCH/dry.json"
)
check "a dry run reports the row it would stamp" \
    "$(json_array "$(cat "$SCRATCH/dry.json")" resolved)" "boxA#1"
check "a dry run says so" "$(json_field "$(cat "$SCRATCH/dry.json")" dry_run)" "True"
check "a dry run leaves the fix alone" \
    "$(sqlite3 "$DB4" 'select fix from invocations where id = 1')" ""
(
    cd "$REPO4" || exit 1
    "$BIN" resolve-merged --db "$DB4" >/dev/null
)
check "a real run stamps after the dry run" \
    "$(sqlite3 "$DB4" "select fix <> '' from invocations where id = 1")" "1"

# -------------------------------------------------------- missing store

REPO5="$(new_repo missing)"
commit_file "$REPO5" "Skill-log-Fix: boxA#1"
(
    cd "$REPO5" || exit 1
    "$BIN" resolve-merged --db "$SCRATCH/no-store/skills.db" --json \
        >"$SCRATCH/missing.json" 2>"$SCRATCH/missing.err"
)
STATUS=$?
check "a missing store exits 0" "$STATUS" "0"
check "a missing store is nothing to do" \
    "$(json_keys "$(cat "$SCRATCH/missing.json")")" \
    "dry_run ignored resolved skipped unchanged"
check "a missing store writes no store" \
    "$([ -e "$SCRATCH/no-store/skills.db" ] && echo created || echo absent)" "absent"
check "a missing store is silent" "$(cat "$SCRATCH/missing.err")" ""

# A table-less file is an empty log, not a schema to create.
: >"$SCRATCH/tableless.db"
BEFORE_SUM="$(md5sum <"$SCRATCH/tableless.db")"
(
    cd "$REPO5" || exit 1
    "$BIN" resolve-merged --db "$SCRATCH/tableless.db" --json \
        >"$SCRATCH/tableless.json" 2>"$SCRATCH/tableless.err"
)
check "a table-less store names the row as unknown" \
    "$(json_array "$(cat "$SCRATCH/tableless.json")" skipped | grep -c 'boxA#1')" "1"
check "a table-less store is not initialised" \
    "$(md5sum <"$SCRATCH/tableless.db")" "$BEFORE_SUM"

# -------------------------------------------------------- artifact mode

REPO6="$(new_repo artifact)"
mkdir -p "$REPO6/.skill-log/reports"
: >"$REPO6/.skill-log/reports/.gitkeep"
printf 'base\n' >"$REPO6/base"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m base
DB6="$SCRATCH/artifact.db"
"$BIN" add --skill by-file --machine boxA --db "$DB6" >/dev/null
"$BIN" add --skill by-trailer --machine boxA --db "$DB6" >/dev/null
printf 'boxA#1\n' >"$REPO6/.skill-log/reports/fix.md"
printf 'change\n' >"$REPO6/file"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m "report the fix" -m "Skill-log-Fix: boxA#2"
REPORT_COMMIT="$(git -C "$REPO6" rev-parse HEAD)"
(
    cd "$REPO6" || exit 1
    "$BIN" resolve-merged --db "$DB6" --json >"$SCRATCH/artifact.json" 2>"$SCRATCH/artifact.err"
)
check "the report file's commit stamps its row" \
    "$(sqlite3 "$DB6" 'select fix from invocations where id = 1')" "$REPORT_COMMIT"
check "a trailer is not read in artifact mode" \
    "$(sqlite3 "$DB6" 'select fix from invocations where id = 2')" ""
check_contains "the ignored trailer is named once" \
    "$(cat "$SCRATCH/artifact.err")" "resolves from .skill-log/reports"

# A bounded second scan says nothing: the hook must not narrate a pull.
(
    cd "$REPO6" || exit 1
    "$BIN" resolve-merged --since "$REPORT_COMMIT" --db "$DB6" \
        >"$SCRATCH/repeat.out" 2>"$SCRATCH/repeat.err"
)
check "a bounded second scan prints nothing" \
    "$(cat "$SCRATCH/repeat.out")$(cat "$SCRATCH/repeat.err")" ""

# A hand-written bad line is reported and never swallowed; the good line
# still resolves.
"$BIN" add --skill by-hand --machine boxA --db "$DB6" >/dev/null
printf 'boxA#3\nnot-a-marker\n' >"$REPO6/.skill-log/reports/bad.md"
printf 'change\n' >"$REPO6/file"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m "a hand-edited report"
(
    cd "$REPO6" || exit 1
    "$BIN" resolve-merged --db "$DB6" --json >"$SCRATCH/hand.json" 2>"$SCRATCH/hand.err"
)
check_contains "a malformed report line is reported with its file" \
    "$(cat "$SCRATCH/hand.err")" \
    "skill-log: not a Skill-log-Fix marker (machine#id): .skill-log/reports/bad.md: not-a-marker"
check "the good line in the same report still resolves" \
    "$(sqlite3 "$DB6" "select fix <> '' from invocations where id = 3")" "1"

# A full scan reads every report file in the tree.
"$BIN" add --skill manual --machine boxA --db "$DB6" >/dev/null
printf 'boxA#4\n' >"$REPO6/.skill-log/reports/manual.md"
printf 'change\n' >"$REPO6/file"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m "a manual report"
(
    cd "$REPO6" || exit 1
    "$BIN" resolve-merged --db "$DB6" --json \
        >"$SCRATCH/manual.json" 2>"$SCRATCH/manual.err"
)
check "a full scan reads every report file" \
    "$(json_array "$(cat "$SCRATCH/manual.json")" resolved)" "boxA#4"

# -------------------------------------------------------------- refusals

printf 'not a database' >"$SCRATCH/damaged.db"
BEFORE_SUM="$(md5sum <"$SCRATCH/damaged.db")"
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$SCRATCH/damaged.db" --quiet >/dev/null 2>"$SCRATCH/damaged.err"
)
STATUS=$?
check "a damaged store exits 1" "$STATUS" "1"
check_contains "a damaged store is named" "$(cat "$SCRATCH/damaged.err")" "damaged store"
check "a damaged store is not written" \
    "$(md5sum <"$SCRATCH/damaged.db")" "$BEFORE_SUM"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
(
    cd "$REPO" || exit 1
    "$BIN" resolve-merged --db "$SCRATCH/foreign.db" --quiet >/dev/null 2>"$SCRATCH/foreign.err"
)
STATUS=$?
check "a foreign store exits 1" "$STATUS" "1"
check_contains "a foreign store is named" "$(cat "$SCRATCH/foreign.err")" "foreign store"

(
    cd "$SCRATCH" || exit 1
    "$BIN" resolve-merged --db "$DB" >/dev/null 2>"$SCRATCH/norepo.err"
)
STATUS=$?
check "outside a checkout exits 1" "$STATUS" "1"
check_contains "outside a checkout is named" "$(cat "$SCRATCH/norepo.err")" \
    "inside a git checkout"

# ------------------------------------------------------------------ help

run resolve-merged --help
check "resolve-merged --help exits 0" "$STATUS" "0"
check "resolve-merged --help writes no stderr" "$ERR" ""
for flag in --since --quiet --dry-run --json --db; do
    check_contains "resolve-merged --help lists $flag" "$OUT" "$flag"
done
check "resolve-merged --help ends with real invocations" \
    "$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "3"
check_contains "resolve-merged --help names the hook path" "$OUT" "post-merge hook"

tally
