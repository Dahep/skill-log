#!/usr/bin/env bash
# The report test: naming the rows a change fixes.
#
#   tests/report.sh
#
# It exercises both modes against the built artifact in sandboxed homes
# and repositories: artifact mode writes `.skill-log/reports/<slug>.md`,
# one marker per line, atomically and only after validation; trailer mode
# prints the `Skill-log-Fix:` line and writes nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-report-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a caller's
# SCRATCH is theirs to clean up.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools git sqlite3 python3

if [ ! -x "$BIN" ]; then
    printf 'report.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
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

# ------------------------------------------------------------------ rows
#
# Four rows: two in one dispatched run (`--session` and `--parent`), one
# clean, and one that a later change already resolved.

run add --skill alpha --machine boxA --session ses_run \
    --problem "secret problem text"
check "the first row is written" "$STATUS" "0"
run add --skill alpha --machine boxA --parent ses_run
check "the second row is written" "$STATUS" "0"
run add --skill beta --machine boxA
check "the third row is written" "$STATUS" "0"
run add --skill gamma --machine boxA
check "the fourth row is written" "$STATUS" "0"

# The row a later change already resolved: the CLI resolves it, the way
# a real change does.
run resolve --id 3 --fix abc123456789 --db "$DB"
check "the third row is resolved" "$STATUS" "0"

# --------------------------------------------------------------- checkouts

# Artifact mode: the report directory exists.
REPO="$SCRATCH/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
printf 'content\n' >"$REPO/file.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial"
git -C "$REPO" checkout -qb feature/thing
mkdir -p "$REPO/.skill-log/reports"

REPORT="$REPO/.skill-log/reports/feature-thing.md"
REL=".skill-log/reports/feature-thing.md"

# Trailer mode: a checkout without the report directory.
PLAIN="$SCRATCH/plain"
mkdir -p "$PLAIN"
git -C "$PLAIN" init -q
git -C "$PLAIN" config user.email "test@example.com"
git -C "$PLAIN" config user.name "Test"
printf 'content\n' >"$PLAIN/file.txt"
git -C "$PLAIN" add -A
git -C "$PLAIN" commit -qm "initial"

# ---------------------------------------------------------------- artifact

cd "$REPO" || exit 1

run report --id 1
check "report exits 0" "$STATUS" "0"
check "report names the file for the branch" "$OUT" \
    "reported 1 marker in $REL"
if [ -f "$REPORT" ]; then
    pass "report writes the branch's file"
else
    fail "report did not write the branch's file"
fi
check "the file holds one marker per line" "$(cat "$REPORT")" "boxA#1"
check "the file ends with a newline" "$(tail -c 1 "$REPORT")" ""
check "the problem text never reaches the report" \
    "$(grep -c 'secret' "$REPORT")" "0"
if [ -e "$REPORT.tmp" ]; then
    fail "report left its temporary file behind"
else
    pass "report replaces the file atomically, with no temporary left"
fi

# A planted symlink at a predictable temporary name cannot redirect the
# write: the temporary is created exclusively under an unpredictable name.
printf 'valuable\n' >"$SCRATCH/victim"
ln -s "$SCRATCH/victim" "$REPO/.skill-log/reports/atomic.md.tmp"
run report --id 4 --slug atomic
check "a planted temp symlink is not followed" \
    "$(cat "$SCRATCH/victim")" "valuable"
check "the report beside a planted symlink is written" \
    "$(cat "$REPO/.skill-log/reports/atomic.md")" "boxA#4"
if [ -L "$REPO/.skill-log/reports/atomic.md.tmp" ]; then
    pass "the planted symlink is left alone"
else
    fail "the planted symlink was consumed"
fi
rm -f "$REPO/.skill-log/reports/atomic.md.tmp"
check "no temporary file is left behind" \
    "$(find "$REPO/.skill-log/reports" -name '*.tmp*' | wc -l | tr -d ' ')" "0"

run report --id 2
check "a second selection unions" "$OUT" "reported 2 markers in $REL"
check "the file holds both markers, sorted" "$(cat "$REPORT")" \
    "$(printf 'boxA#1\nboxA#2')"

# Re-running over an unchanged report writes nothing and says so.
BEFORE_SUM="$(md5sum <"$REPORT")"
BEFORE_MTIME="$(stat -c %Y "$REPORT")"
run report --id 2
check "an unchanged report is already reported" "$OUT" \
    "already reported: $REL (2 markers)"
check "an unchanged report is not rewritten" \
    "$(md5sum <"$REPORT")" "$BEFORE_SUM"
run report --id 1 --id 2
check "a repeated selection is already reported" "$STATUS" "0"

run report --run ses_run --slug run-report
check "--run selects the session and the parent" "$OUT" \
    "reported 2 markers in .skill-log/reports/run-report.md"
check "--run writes both markers" \
    "$(cat "$REPO/.skill-log/reports/run-report.md")" \
    "$(printf 'boxA#1\nboxA#2')"

run report --skill alpha --slug alpha-report
check "--skill selects that skill's rows" "$OUT" \
    "reported 2 markers in .skill-log/reports/alpha-report.md"

# A row a change already closed is skipped and named, not rewritten.
run report --id 3 --slug closed
check "a resolved row exits 0" "$STATUS" "0"
check "a resolved row reports nothing to write" "$OUT" \
    "nothing to report: the selected rows are already resolved"
check "a resolved row is named on stderr" "$ERR" \
    "skill-log: boxA#3 already resolved; skipped"
if [ -e "$REPO/.skill-log/reports/closed.md" ]; then
    fail "a resolved row wrote a report"
else
    pass "a resolved row writes no report"
fi

# ------------------------------------------------------------------ ids

run report --id 99
check "an unknown id exits 1" "$STATUS" "1"
check "an unknown id is named" "$ERR" \
    "skill-log: no invocation 99 in $DB"
check_one_line "an unknown id is one line" "$ERR"
if [ -e "$REPO/.skill-log/reports/feature-thing.md.tmp" ]; then
    fail "an unknown id left a temporary file"
else
    pass "an unknown id writes nothing"
fi

run report --id 1 --id 99
check "one unknown id fails the whole selection" "$STATUS" "1"
check "the unknown id is named even beside a known one" "$ERR" \
    "skill-log: no invocation 99 in $DB"

run report --id 0
check "--id 0 exits 2" "$STATUS" "2"
check_one_line "--id 0 is one line" "$ERR"
run report --id abc
check "--id abc exits 2" "$STATUS" "2"
check_one_line "--id abc is one line" "$ERR"
run report --id
check "a missing --id value exits 2" "$STATUS" "2"
check_one_line "a missing --id value is one line" "$ERR"

run report
check "no selector exits 2" "$STATUS" "2"
check_contains "no selector carries an example" "$ERR" \
    "for example: skill-log report --run ses_abc123"
check_one_line "no selector is one line" "$ERR"

run report --id 1 --nope
check "an unknown flag exits 2" "$STATUS" "2"
check_one_line "an unknown flag is one line" "$ERR"

run report --run ""
check "an empty --run exits 2" "$STATUS" "2"
run report --skill ""
check "an empty --skill exits 2" "$STATUS" "2"
run report --slug ""
check "an empty --slug exits 2" "$STATUS" "2"

# A flag's value is taken as written: `--id -h` is the value `-h`.
run report --id -h
check "a --id value spelled -h is a value" "$STATUS" "2"
check_contains "a --id value spelled -h is a malformed id" "$ERR" \
    "--id takes a positive integer"
run report --skill alpha -h
check "a help flag after a value still asks for help" "$STATUS" "0"
check "the help block is the verb's usage" \
    "$(printf '%s\n' "$OUT" | grep -c '^usage:$')" "1"

# -------------------------------------------------------------- dry runs

run report --id 4 --slug dry --dry-run
check "a dry run exits 0" "$STATUS" "0"
check "a dry run says what it would write" "$OUT" \
    "would report 1 marker in .skill-log/reports/dry.md"
if [ -e "$REPO/.skill-log/reports/dry.md" ]; then
    fail "a dry run wrote the report"
else
    pass "a dry run writes nothing"
fi

# ------------------------------------------------------------------- json

run report --id 4 --slug json-report --json
check "json exits 0" "$STATUS" "0"
check "json carries the path and the markers" "$(json_keys "$OUT")" \
    "already_reported already_resolved dry_run markers path trailer"
check "json names the file" "$(json_field "$OUT" path)" \
    ".skill-log/reports/json-report.md"
check "json carries the marker" "$(json_array "$OUT" markers)" "boxA#4"
check "json says it wrote" "$(json_field "$OUT" already_reported)" "False"
check "json carries no trailer in artifact mode" \
    "$(json_field "$OUT" trailer)" ""

run report --id 4 --slug json-report --json
check "json says an unchanged report is already reported" \
    "$(json_field "$OUT" already_reported)" "True"

# -------------------------------------------------------------- union/check

# A marker from another machine is kept, sorted, and warned about — its
# store is elsewhere, and that machine resolves it.
printf 'otherbox#7\n' >"$REPO/.skill-log/reports/union.md"
run report --id 4 --slug union
check "a foreign marker is kept in the union" \
    "$(cat "$REPO/.skill-log/reports/union.md")" \
    "$(printf 'boxA#4\notherbox#7')"

run report --check --slug union
check "a report with a foreign marker is valid" "$STATUS" "0"
check "the foreign marker is a warning" "$ERR" \
    "skill-log: otherbox#7: not in this db (resolves where it is)"
check "the check names the valid file and its count" "$OUT" \
    ".skill-log/reports/union.md is valid (2 markers)"
run report --check --slug union --json
check "the check's json carries the warnings" \
    "$(json_array "$OUT" warnings)" \
    "otherbox#7: not in this db (resolves where it is)"

# A marker this store has and has already resolved is warned about too.
printf 'boxA#3\n' >"$REPO/.skill-log/reports/closed.md"
run report --check --slug closed
check "a resolved marker is a warning, not a problem" "$STATUS" "0"
check "the resolved marker names its commit" "$ERR" \
    "skill-log: boxA#3: already resolved by abc123456"

# A line that is not a marker is a problem: fail, name the line.
printf 'not a marker\n' >"$REPO/.skill-log/reports/broken.md"
run report --check --slug broken
check "a malformed line fails the check" "$STATUS" "1"
check_contains "the malformed line names its position" "$ERR" \
    "skill-log: .skill-log/reports/broken.md:1: not a marker (machine#id): not a marker"
check "the failure is one summary line on top of the findings" \
    "$(printf '%s\n' "$ERR" | grep -c 'is not a valid report')" "1"
run report --check --slug broken --json
check "the check's json carries the problems" \
    "$(json_array "$OUT" problems)" \
    ".skill-log/reports/broken.md:1: not a marker (machine#id): not a marker"

printf 'not a marker\n' >"$REPO/.skill-log/reports/bad-write.md"
BEFORE_SUM="$(md5sum <"$REPO/.skill-log/reports/bad-write.md")"
run report --id 4 --slug bad-write
check "a write over a malformed report exits 1" "$STATUS" "1"
check "a write over a malformed report leaves it alone" \
    "$(md5sum <"$REPO/.skill-log/reports/bad-write.md")" "$BEFORE_SUM"

# A marker this store cannot parse back is never written into a file.
sqlite3 "$DB" "update invocations set machine = 'bad#machine' where id = 4"
run report --id 4 --slug bad-machine
check "an unnameable machine is refused" "$STATUS" "1"
check "an unnameable machine is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'not a marker (machine#id)')" "1"
if [ -e "$REPO/.skill-log/reports/bad-machine.md" ]; then
    fail "an unnameable machine wrote a report"
else
    pass "an unnameable machine writes no report"
fi
printf 'bad#machine#4\n' >"$REPO/.skill-log/reports/bad-line.md"
run report --check --slug bad-line
check "a report with an unparseable marker is not valid" "$STATUS" "1"
check_contains "the unparseable marker names its position" "$ERR" \
    "not a marker (machine#id)"
sqlite3 "$DB" "update invocations set machine = 'boxA' where id = 4"

run report --check --slug no-such-report
check "a missing report file exits 0" "$STATUS" "0"
check "a missing report file says so" "$OUT" \
    "no report file at .skill-log/reports/no-such-report.md"

# ------------------------------------------- the check names the right file
#
# The check reads two things: the report file and the store. A failure in
# one is not a failure in the other, and the message has to name the one
# that actually failed.
printf 'boxA#4\n' >"$REPO/.skill-log/reports/unreadable.md"
chmod 000 "$REPO/.skill-log/reports/unreadable.md"
run report --check --slug unreadable
check "an unreadable report exits 1" "$STATUS" "1"
check_contains "an unreadable report is named as the report" "$ERR" \
    "cannot read the report: $REPO/.skill-log/reports/unreadable.md"
check_absent "an unreadable report is not blamed on the store" "$ERR" \
    "damaged store"
check_absent "an unreadable report is not called a store failure" "$ERR" \
    "cannot read the store"
check_one_line "an unreadable report is one line" "$ERR"
chmod 0644 "$REPO/.skill-log/reports/unreadable.md"

# A report path that carries the vocabulary does not decide the store's
# verdict: the check still succeeds, and the store is not named at all.
printf 'boxA#4\n' >"$REPO/.skill-log/reports/malformed.md"
run report --check --slug malformed --db "$SCRATCH/malformed/locked.db"
check "a report path with a vocabulary word still checks" "$STATUS" "0"
check_contains "the check names the valid report" "$OUT" \
    ".skill-log/reports/malformed.md is valid (1 marker)"
check_absent "the store is not blamed for the report" "$ERR" "damaged store"
check_absent "the store is not called locked" "$ERR" "locked store"

# --------------------------------------------------------------- naming

run report --id 4 --slug "../evil"
check "a traversal slug cannot escape the report directory" "$OUT" \
    "reported 1 marker in .skill-log/reports/evil.md"
if [ -f "$REPO/evil.md" ]; then
    fail "a traversal slug wrote outside the directory"
else
    pass "a traversal slug stays inside the report directory"
fi

# Detached HEAD names no branch; --slug is the way out.
git -C "$REPO" checkout -q --detach
run report --id 4
check "a detached HEAD exits 1" "$STATUS" "1"
check "a detached HEAD asks for --slug" "$ERR" \
    "skill-log: cannot name the report file (detached HEAD?); pass --slug"
run report --id 4 --slug detached
check "a detached HEAD with --slug works" "$STATUS" "0"
git -C "$REPO" checkout -q feature/thing

cd "$SCRATCH" || exit 1
run report --id 1
check "outside a checkout report exits 1" "$STATUS" "1"
check "outside a checkout report says where it must run" "$ERR" \
    "skill-log: report runs inside a git checkout (the report lives there)"

# ---------------------------------------------------------------- trailer

cd "$PLAIN" || exit 1

run report --id 4
check "trailer mode exits 0" "$STATUS" "0"
check "trailer mode prints the trailer" "$OUT" "Skill-log-Fix: boxA#4"
check "trailer mode says where the line belongs" "$ERR" \
    "skill-log: no .skill-log/reports/ here; put the trailer in the commit body"
if [ -e "$PLAIN/.skill-log" ]; then
    fail "trailer mode created the report directory"
else
    pass "trailer mode creates nothing"
fi

run report --id 4 --json
check "trailer mode json carries no path" "$(json_field "$OUT" path)" ""
check "trailer mode json carries the trailer" \
    "$(json_field "$OUT" trailer)" "Skill-log-Fix: boxA#4"
check "trailer mode json carries the markers" \
    "$(json_array "$OUT" markers)" "boxA#4"

run report --run ses_run
check "trailer mode carries one line for a tree" "$OUT" \
    "Skill-log-Fix: boxA#1, boxA#2"

run report --id 3
check "trailer mode skips a resolved row" "$STATUS" "0"
check "trailer mode names the skipped row" "$ERR" \
    "skill-log: boxA#3 already resolved; skipped"

run report --check
check "trailer mode check exits 0" "$STATUS" "0"
check "trailer mode check explains the mode" "$OUT" \
    "no .skill-log/reports/ here: this checkout resolves from the Skill-log-Fix trailer"
run report --check --json
check "trailer mode check json has no path" "$(json_field "$OUT" path)" ""

# --------------------------------------------------------------- refusals

cd "$REPO" || exit 1

printf 'not a database' >"$SCRATCH/damaged.db"
run report --id 1 --db "$SCRATCH/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check "a damaged store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'damaged store')" "1"

sqlite3 "$SCRATCH/foreign.db" 'create table something (x)'
run report --id 1 --db "$SCRATCH/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check "a foreign store is named" \
    "$(printf '%s\n' "$ERR" | grep -c 'foreign store')" "1"

# An existing but table-less store is an empty log: a named id is a
# missing id, not a silent "nothing to report".
: >"$SCRATCH/tableless.db"
run report --id 99 --db "$SCRATCH/tableless.db" --slug tableless
check "a table-less store names the missing id" "$STATUS" "1"
check "a table-less store names the id" "$ERR" \
    "skill-log: no invocation 99 in $SCRATCH/tableless.db"
run report --run nope --db "$SCRATCH/tableless.db" --slug tableless
check "a table-less store has nothing to report for a run" "$OUT" \
    "nothing to report: the selected rows are already resolved"
printf 'boxA#1\n' >"$REPO/.skill-log/reports/tableless-check.md"
run report --check --slug tableless-check --db "$SCRATCH/tableless.db"
check "a table-less store still checks report syntax" "$STATUS" "0"
check "a table-less store check is valid" "$OUT" \
    ".skill-log/reports/tableless-check.md is valid (1 marker)"

run report --id 1 --db "$SCRATCH/none.db"
check "a missing store exits 1" "$STATUS" "1"
check "a missing store says to add first" "$ERR" \
    "skill-log: no store at $SCRATCH/none.db (run add first)"

# ------------------------------------------------------- reads never write

BEFORE_SUM="$(md5sum <"$REPORT")"
BEFORE_MTIME="$(stat -c %Y "$REPORT")"
run report --check
run report --id 1 --json
run report --id 4 --slug check-only --dry-run
check "a check leaves the report byte-identical" \
    "$(md5sum <"$REPORT")" "$BEFORE_SUM"
check "a check leaves the report's mtime alone" \
    "$(stat -c %Y "$REPORT")" "$BEFORE_MTIME"
if [ -e "$REPO/.skill-log/reports/check-only.md" ]; then
    fail "a dry run wrote a report"
else
    pass "a dry run leaves no report behind"
fi

# ------------------------------------------------------------------ help

run report --help
check "report --help exits 0" "$STATUS" "0"
for flag in --id --run --skill --slug --check --dry-run --json --db; do
    check_contains "report --help lists $flag" "$OUT" "$flag"
done
check "report --help ends with 2 to 4 real invocations" \
    "$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "4"
check_contains "report --help names the trailer" "$OUT" "Skill-log-Fix"

# ----------------------------------------------------------------- report

tally
