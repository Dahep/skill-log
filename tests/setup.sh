#!/usr/bin/env bash
# The setup test: `setup` against the built artifact, in a sandboxed home.
#
#   tests/setup.sh
#
# It exercises the seam the contract is written against — the installed
# binary as a process — with a temporary HOME, a temporary XDG state
# directory, and temporary git repositories (one linked as a worktree, to
# prove the common hooks directory is used). No real store and no real
# hook is anywhere near it.
#
# Cases: creation and the no-op re-run, --check clean and per-artifact
# drift with nothing written, a foreign post-merge refused and preserved,
# --remove-hook on a marked and on a foreign hook, a non-git checkout
# skipped with exit 0, --no-hook/--no-report-dir, the --json shape,
# --dry-run writing nothing, a report directory with content left
# byte-for-byte alone, the generated hook's CLI-resolution fallbacks and
# its --since argument, pulls that keep their exit status with a failing
# or absent CLI, the machine line, the skills verdict, the store
# refusals, and usage errors.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-setup}"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools git python3 sqlite3

if [ ! -x "$BIN" ]; then
    printf 'setup.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" "$SCRATCH/tmp"

HOME_DIR="$SCRATCH/home"
TMP="$SCRATCH/tmp"
GIT_BIN="$(command -v git)"

# run <args...>: the binary with no inherited store configuration and a
# scratch HOME. Output lands in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$(env -u XDG_STATE_HOME -u SKILL_LOG_DB -u XDG_CONFIG_HOME \
        -u SKILL_LOG_TEMPLATE_DIR \
        HOME="$HOME_DIR" "$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

DB="$HOME_DIR/.local/state/skill-log/skills.db"

# make_repo <dir>: a git repository with one commit.
make_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf 'one\n' >"$repo/file"
    git -C "$repo" add file
    git -C "$repo" commit -q -m initial
}

# bump <dir> <name>: one more commit, for a reflog that has HEAD@{1}.
bump() {
    printf 'x\n' >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$2"
}

# The human verdict lines are `status  artifact  detail`; the machine
# line is not one. Two spaces separate the columns.
status_of() { # status_of <out> <artifact>
    printf '%s\n' "$1" | awk -F'  ' -v a="$2" '$2 == a { print $1 }'
}

detail_of() { # detail_of <out> <artifact>
    printf '%s\n' "$1" | awk -F'  ' -v a="$2" '$2 == a { print $3 }'
}

# ------------------------------------------------------------- creation
#
# One command makes the repo and the machine ready; a second run is a
# no-op.

make_repo "$TMP/r1"
run setup --repo "$TMP/r1"
check "setup exits 0" "$STATUS" "0"
check "setup: the store verdict is created" \
    "$(status_of "$OUT" store)" "created"
check "setup: the hook verdict is created" \
    "$(status_of "$OUT" hook)" "created"
check "setup: the report dir verdict is created" \
    "$(status_of "$OUT" report_dir)" "created"
check "setup: the skills verdict is skipped" \
    "$(status_of "$OUT" skills)" "skipped"
check_contains "setup: the skills skip reason is named" \
    "$(detail_of "$OUT" skills)" "no --skills-dir given"
check_contains "setup: the human output names the machine" \
    "$(printf '%s\n' "$OUT" | head -n 1)" "machine: $(hostname)"

HOOK="$TMP/r1/.git/hooks/post-merge"
if [ -f "$DB" ]; then pass "setup: the store file exists"; else
    fail "setup: the store file exists"
fi
if [ -x "$HOOK" ]; then pass "setup: the hook is executable"; else
    fail "setup: the hook is executable"
fi
check_contains "setup: the hook carries the ownership marker" \
    "$(cat "$HOOK")" "# skill-log:post-merge-hook"
check "setup: the hook is a shell script" \
    "$(head -n 1 "$HOOK")" "#!/bin/sh"
if [ -f "$TMP/r1/.skill-log/reports/README.md" ]; then
    pass "setup: the report directory carries its README"
else
    fail "setup: the report directory carries its README"
fi
if [ -f "$TMP/r1/.skill-log/reports/.keep" ]; then
    pass "setup: the report directory carries its keep file"
else
    fail "setup: the report directory carries its keep file"
fi

cp "$HOOK" "$SCRATCH/hook.before"
cp "$TMP/r1/.skill-log/reports/README.md" "$SCRATCH/readme.before"
DB_SUM="$(cksum <"$DB")"

run setup --repo "$TMP/r1"
check "re-run exits 0" "$STATUS" "0"
check "re-run: the store is unchanged" "$(status_of "$OUT" store)" "unchanged"
check "re-run: the hook is unchanged" "$(status_of "$OUT" hook)" "unchanged"
check "re-run: the report dir is unchanged" \
    "$(status_of "$OUT" report_dir)" "unchanged"
if cmp -s "$HOOK" "$SCRATCH/hook.before"; then
    pass "re-run: the hook is byte-identical"
else
    fail "re-run: the hook is byte-identical"
fi
if cmp -s "$TMP/r1/.skill-log/reports/README.md" "$SCRATCH/readme.before"; then
    pass "re-run: the README is byte-identical"
else
    fail "re-run: the README is byte-identical"
fi
check "re-run: the store bytes did not move" "$(cksum <"$DB")" "$DB_SUM"

# --------------------------------------------------------------- check
#
# --check asks each owner for its verdict and writes nothing: clean is
# exit 0, and every drift is exit 1 with the state untouched.

run setup --repo "$TMP/r1" --check
check "check on a fresh setup exits 0" "$STATUS" "0"
check "check: the store is unchanged" "$(status_of "$OUT" store)" "unchanged"
check "check: the hook is unchanged" "$(status_of "$OUT" hook)" "unchanged"
check "check: the report dir is unchanged" \
    "$(status_of "$OUT" report_dir)" "unchanged"

# drift: the store is missing.
rm -f "$DB"
run setup --repo "$TMP/r1" --check
check "check: a missing store exits 1" "$STATUS" "1"
check "check: a missing store is drift" "$(status_of "$OUT" store)" "drift"
check_contains "check: the drift names the store path" \
    "$(detail_of "$OUT" store)" "no store at $DB"
check "check: the store is not written" "$([ -f "$DB" ] && echo yes || echo no)" "no"
check_one_line "check: one stderr line" "$ERR"

# drift: the hook is missing.
run setup --repo "$TMP/r1"
rm -f "$HOOK"
run setup --repo "$TMP/r1" --check
check "check: a missing hook exits 1" "$STATUS" "1"
check "check: a missing hook is drift" "$(status_of "$OUT" hook)" "drift"
check_contains "check: the drift names the hook path" \
    "$(detail_of "$OUT" hook)" "no post-merge hook at $HOOK"
check "check: the hook is not written" "$([ -e "$HOOK" ] && echo yes || echo no)" "no"

# drift: the ownership marker was stripped from the hook.
run setup --repo "$TMP/r1"
sed -i '/^# skill-log:post-merge-hook$/d' "$HOOK"
cp "$HOOK" "$SCRATCH/hook.nomarker"
run setup --repo "$TMP/r1" --check
check "check: a stripped marker exits 1" "$STATUS" "1"
check "check: a stripped marker is drift" "$(status_of "$OUT" hook)" "drift"
check_contains "check: the drift names the missing marker" \
    "$(detail_of "$OUT" hook)" "ownership marker"
if cmp -s "$HOOK" "$SCRATCH/hook.nomarker"; then
    pass "check: the unmarked hook is left byte-for-byte alone"
else
    fail "check: the unmarked hook is left byte-for-byte alone"
fi

# drift: the report directory is missing.
run setup --repo "$TMP/r1"
rm -rf "$TMP/r1/.skill-log"
run setup --repo "$TMP/r1" --check
check "check: a missing report directory exits 1" "$STATUS" "1"
check "check: a missing report directory is drift" \
    "$(status_of "$OUT" report_dir)" "drift"
check_contains "check: the drift names the directory" \
    "$(detail_of "$OUT" report_dir)" "no report directory at"
check "check: the report directory is not written" \
    "$([ -e "$TMP/r1/.skill-log" ] && echo yes || echo no)" "no"

# ------------------------------------------------------- foreign hook
#
# A post-merge this tool did not write is refused by name and never
# overwritten.

make_repo "$TMP/r2"
printf '#!/bin/sh\necho foreign\n' >"$TMP/r2/.git/hooks/post-merge"
chmod +x "$TMP/r2/.git/hooks/post-merge"
cp "$TMP/r2/.git/hooks/post-merge" "$SCRATCH/foreign.before"
run setup --repo "$TMP/r2"
check "a foreign hook exits 1" "$STATUS" "1"
check_contains "a foreign hook is refused by name" "$ERR" "ownership marker"
check_contains "a foreign hook refusal names the path" "$ERR" \
    "$TMP/r2/.git/hooks/post-merge"
check_one_line "a foreign hook refusal is one line" "$ERR"
if cmp -s "$TMP/r2/.git/hooks/post-merge" "$SCRATCH/foreign.before"; then
    pass "a foreign hook is preserved byte-for-byte"
else
    fail "a foreign hook is preserved byte-for-byte"
fi

# ---------------------------------------------------------- remove hook
#
# --remove-hook removes only a hook carrying the ownership marker.

rm -f "$HOOK"
run setup --repo "$TMP/r1"
run setup --repo "$TMP/r1" --remove-hook
check "--remove-hook exits 0" "$STATUS" "0"
check "--remove-hook: the hook verdict is updated" \
    "$(status_of "$OUT" hook)" "updated"
check_contains "--remove-hook: the detail says removed" \
    "$(detail_of "$OUT" hook)" "removed"
check "--remove-hook: the marked hook is gone" \
    "$([ -e "$HOOK" ] && echo yes || echo no)" "no"

cp "$SCRATCH/foreign.before" "$TMP/r2/.git/hooks/post-merge"
chmod +x "$TMP/r2/.git/hooks/post-merge"
run setup --repo "$TMP/r2" --remove-hook
check "--remove-hook on a foreign hook exits 0" "$STATUS" "0"
check "--remove-hook: a foreign hook is skipped" \
    "$(status_of "$OUT" hook)" "skipped"
check_contains "--remove-hook: the skip names the marker" \
    "$(detail_of "$OUT" hook)" "ownership marker"
if cmp -s "$TMP/r2/.git/hooks/post-merge" "$SCRATCH/foreign.before"; then
    pass "--remove-hook leaves a foreign hook alone"
else
    fail "--remove-hook leaves a foreign hook alone"
fi

# ------------------------------------------------------- non-git dir
#
# A checkout that is not a git repository skips the repo-scoped
# artifacts with a named reason and exits 0.

mkdir -p "$TMP/plain"
run setup --repo "$TMP/plain" --db "$TMP/plain-store.db"
check "non-git: exits 0" "$STATUS" "0"
check "non-git: the hook is skipped" "$(status_of "$OUT" hook)" "skipped"
check_contains "non-git: the hook skip is named" \
    "$(detail_of "$OUT" hook)" "not a git checkout"
check "non-git: the report dir is skipped" \
    "$(status_of "$OUT" report_dir)" "skipped"
check_contains "non-git: the report dir skip is named" \
    "$(detail_of "$OUT" report_dir)" "not a git checkout"
check "non-git: nothing is created in the directory" \
    "$([ -e "$TMP/plain/.skill-log" ] && echo yes || echo no)" "no"
check "non-git: the store is still created" \
    "$([ -f "$TMP/plain-store.db" ] && echo yes)" "yes"

# ----------------------------------------------------------- no flags
#
# --no-hook and --no-report-dir turn one artifact off.

make_repo "$TMP/r5"
run setup --repo "$TMP/r5" --no-hook --no-report-dir --db "$TMP/r5-store.db"
check "--no-hook/--no-report-dir exit 0" "$STATUS" "0"
check "--no-hook: the hook is skipped" "$(status_of "$OUT" hook)" "skipped"
check_contains "--no-hook: the skip is named" \
    "$(detail_of "$OUT" hook)" "--no-hook"
check "--no-report-dir: the report dir is skipped" \
    "$(status_of "$OUT" report_dir)" "skipped"
check_contains "--no-report-dir: the skip is named" \
    "$(detail_of "$OUT" report_dir)" "--no-report-dir"
check "--no-hook: no hook is written" \
    "$([ -e "$TMP/r5/.git/hooks/post-merge" ] && echo yes || echo no)" "no"
check "--no-report-dir: no report directory is written" \
    "$([ -e "$TMP/r5/.skill-log" ] && echo yes || echo no)" "no"

# --------------------------------------------------------------- json
#
# One object per artifact examined, exactly the keys the contract names.

make_repo "$TMP/rjson"
run setup --repo "$TMP/rjson" --dry-run --json --db "$TMP/rjson-store.db"
check "json: --dry-run --json exits 0" "$STATUS" "0"
check "json: one object per artifact" \
    "$(printf '%s\n' "$OUT" | grep -c '^{"artifact":')" "4"
check "json: the shape is the contract's" \
    "$(printf '%s' "$OUT" | python3 -c '
import json, sys
objects = [json.loads(line) for line in sys.stdin.read().splitlines()]
verdict = "ok"
if [o["artifact"] for o in objects] != ["store", "hook", "report_dir", "skills"]:
    verdict = "artifact order"
if [o["status"] for o in objects] != ["created", "created", "created", "skipped"]:
    verdict = "statuses"
for o in objects:
    if sorted(o.keys()) != ["artifact", "detail", "status"]:
        verdict = "keys"
print(verdict)
')" "ok"
check "json: nothing is written" "$([ -e "$TMP/rjson/.git/hooks/post-merge" ] && echo yes || echo no)" "no"

run setup --repo "$TMP/rjson" --check --json --db "$TMP/rjson-store.db"
check "json: drift exits 1" "$STATUS" "1"
check_contains "json: the drift status is in the output" \
    "$OUT" '"status":"drift"'
check_one_line "json: the failure is one stderr line" "$ERR"

# ------------------------------------------------------------- dry-run
#
# --dry-run shows the changes and writes nothing.

make_repo "$TMP/rdry"
run setup --repo "$TMP/rdry" --dry-run --db "$TMP/rdry-store.db"
check "dry-run exits 0" "$STATUS" "0"
check "dry-run: the store verdict is created" \
    "$(status_of "$OUT" store)" "created"
check "dry-run: the hook verdict is created" \
    "$(status_of "$OUT" hook)" "created"
check "dry-run: the report dir verdict is created" \
    "$(status_of "$OUT" report_dir)" "created"
check "dry-run: no store is written" \
    "$([ -f "$TMP/rdry-store.db" ] && echo yes || echo no)" "no"
check "dry-run: no hook is written" \
    "$([ -e "$TMP/rdry/.git/hooks/post-merge" ] && echo yes || echo no)" "no"
check "dry-run: no report directory is written" \
    "$([ -e "$TMP/rdry/.skill-log" ] && echo yes || echo no)" "no"

# ----------------------------------------------- report dir with content
#
# A report directory that already exists is left byte-for-byte alone.

make_repo "$TMP/r7"
mkdir -p "$TMP/r7/.skill-log/reports"
printf 'my own readme\n' >"$TMP/r7/.skill-log/reports/README.md"
printf '%s#1\n' "$(hostname)" >"$TMP/r7/.skill-log/reports/topic.md"
cp "$TMP/r7/.skill-log/reports/README.md" "$SCRATCH/custom.before"
cp "$TMP/r7/.skill-log/reports/topic.md" "$SCRATCH/report.before"
run setup --repo "$TMP/r7"
check "existing report dir: exits 0" "$STATUS" "0"
check "existing report dir: the verdict is updated" \
    "$(status_of "$OUT" report_dir)" "updated"
if cmp -s "$TMP/r7/.skill-log/reports/README.md" "$SCRATCH/custom.before"; then
    pass "existing report dir: the README is byte-for-byte alone"
else
    fail "existing report dir: the README is byte-for-byte alone"
fi
if cmp -s "$TMP/r7/.skill-log/reports/topic.md" "$SCRATCH/report.before"; then
    pass "existing report dir: the report file is byte-for-byte alone"
else
    fail "existing report dir: the report file is byte-for-byte alone"
fi
if [ -f "$TMP/r7/.skill-log/reports/.keep" ]; then
    pass "existing report dir: the keep file is added"
else
    fail "existing report dir: the keep file is added"
fi

make_repo "$TMP/r7b"
mkdir -p "$TMP/r7b/.skill-log/reports"
printf 'my own readme\n' >"$TMP/r7b/.skill-log/reports/README.md"
: >"$TMP/r7b/.skill-log/reports/.keep"
printf '%s#2\n' "$(hostname)" >"$TMP/r7b/.skill-log/reports/topic.md"
DB7B="$TMP/r7b-store.db"
run setup --repo "$TMP/r7b" --db "$DB7B"
check "complete report dir: the verdict is unchanged" \
    "$(status_of "$OUT" report_dir)" "unchanged"
if cmp -s "$TMP/r7b/.skill-log/reports/README.md" "$SCRATCH/custom.before"; then
    pass "complete report dir: the README is byte-for-byte alone"
else
    fail "complete report dir: the README is byte-for-byte alone"
fi
# shellcheck disable=SC2012  # the entries are tool-written names, no odd bytes
check "complete report dir: only the three entries exist" \
    "$(ls -A "$TMP/r7b/.skill-log/reports" | sort | tr '\n' ' ')" \
    ".keep README.md topic.md "

# ------------------------------------------------------------- the hook
#
# The generated hook resolves the CLI at run time, derives the pre-merge
# reflog position, and exits 0 whatever the CLI does.

make_repo "$TMP/rhook"
bump "$TMP/rhook" two
SINCE="$(git -C "$TMP/rhook" rev-parse 'HEAD@{1}')"
run setup --repo "$TMP/rhook" --db "$TMP/rhook-store.db"
HOOK8="$TMP/rhook/.git/hooks/post-merge"

# A logging CLI on PATH: branch one of the resolution order.
FAKE1="$SCRATCH/fake1"
mkdir -p "$FAKE1"
ln -s "$GIT_BIN" "$FAKE1/git"
cat >"$FAKE1/skill-log" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SCRATCH/cli1.log"
exit 0
EOF
chmod +x "$FAKE1/skill-log"
rm -f "$SCRATCH/cli1.log"

( cd "$TMP/rhook" && env HOME="$HOME_DIR" PATH="$FAKE1" \
    SKILL_LOG_DB="$TMP/rhook-store.db" "$HOOK8" ) \
    >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err"
check "hook: exits 0" "$?" "0"
check "hook: prints nothing" \
    "$(wc -c <"$SCRATCH/hook.out" | tr -d ' ')" "0"
check "hook: writes nothing to stderr" \
    "$(wc -c <"$SCRATCH/hook.err" | tr -d ' ')" "0"
check "hook: passes the pre-merge reflog position" \
    "$(cat "$SCRATCH/cli1.log" 2>/dev/null)" \
    "resolve-merged --since $SINCE --quiet"

# No skill-log on PATH, but mise is: branch two.
FAKE2="$SCRATCH/fake2"
mkdir -p "$FAKE2"
ln -s "$GIT_BIN" "$FAKE2/git"
cat >"$FAKE2/mise" <<EOF
#!/bin/sh
if [ "\$1" = "which" ] && [ "\$2" = "skill-log" ]; then
    printf '%s\n' "$FAKE2/mise-skill-log"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE2/mise"
cat >"$FAKE2/mise-skill-log" <<EOF
#!/bin/sh
printf 'mise:%s\n' "\$*" >>"$SCRATCH/cli2.log"
exit 0
EOF
chmod +x "$FAKE2/mise-skill-log"
rm -f "$SCRATCH/cli2.log"

( cd "$TMP/rhook" && env HOME="$HOME_DIR" PATH="$FAKE2" \
    SKILL_LOG_DB="$TMP/rhook-store.db" "$HOOK8" ) \
    >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err"
check "hook: the mise fallback runs" \
    "$(cat "$SCRATCH/cli2.log" 2>/dev/null)" \
    "mise:resolve-merged --since $SINCE --quiet"

# Neither on PATH: the shim under $HOME is branch three.
FAKE3="$SCRATCH/fake3"
mkdir -p "$FAKE3" "$HOME_DIR/.local/share/mise/shims"
ln -s "$GIT_BIN" "$FAKE3/git"
cat >"$HOME_DIR/.local/share/mise/shims/skill-log" <<EOF
#!/bin/sh
printf 'shim:%s\n' "\$*" >>"$SCRATCH/cli3.log"
exit 0
EOF
chmod +x "$HOME_DIR/.local/share/mise/shims/skill-log"
rm -f "$SCRATCH/cli3.log"

( cd "$TMP/rhook" && env HOME="$HOME_DIR" PATH="$FAKE3" \
    SKILL_LOG_DB="$TMP/rhook-store.db" "$HOOK8" ) \
    >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err"
check "hook: the shim fallback runs" \
    "$(cat "$SCRATCH/cli3.log" 2>/dev/null)" \
    "shim:resolve-merged --since $SINCE --quiet"

# Nothing resolves: exit 0 silently.
rm -rf "$HOME_DIR/.local/share/mise"
rm -f "$SCRATCH/cli4.log"
( cd "$TMP/rhook" && env HOME="$HOME_DIR" PATH="$FAKE3" \
    SKILL_LOG_DB="$TMP/rhook-store.db" "$HOOK8" ) \
    >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err"
check "hook: no CLI found exits 0" "$?" "0"
check "hook: no CLI found is silent on stdout" \
    "$(wc -c <"$SCRATCH/hook.out" | tr -d ' ')" "0"
check "hook: no CLI found is silent on stderr" \
    "$(wc -c <"$SCRATCH/hook.err" | tr -d ' ')" "0"

# A failing CLI: the hook still exits 0 and says nothing.
FAKE5="$SCRATCH/fake5"
mkdir -p "$FAKE5"
ln -s "$GIT_BIN" "$FAKE5/git"
cat >"$FAKE5/skill-log" <<EOF
#!/bin/sh
printf 'failing:%s\n' "\$*" >>"$SCRATCH/cli5.log"
printf 'an older skill-log\n' >&2
exit 2
EOF
chmod +x "$FAKE5/skill-log"
rm -f "$SCRATCH/cli5.log"

( cd "$TMP/rhook" && env HOME="$HOME_DIR" PATH="$FAKE5" \
    SKILL_LOG_DB="$TMP/rhook-store.db" "$HOOK8" ) \
    >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err"
check "hook: a failing CLI still exits 0" "$?" "0"
check "hook: a failing CLI leaves stderr alone" \
    "$(wc -c <"$SCRATCH/hook.err" | tr -d ' ')" "0"
check "hook: a failing CLI was still called" \
    "$(cat "$SCRATCH/cli5.log" 2>/dev/null)" \
    "failing:resolve-merged --since $SINCE --quiet"

# ------------------------------------------------------------- the pull
#
# The acceptance case: a pull keeps its exit status whatever the CLI
# does, and the hook contributes nothing to the output.

make_repo "$TMP/origin"
git clone -q "$TMP/origin" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" config user.email test@example.com
git -C "$TMP/clone" config user.name test
git -C "$TMP/clone" config commit.gpgsign false
git -C "$TMP/clone" config pull.rebase false
git -C "$TMP/clone" config pull.ff false

# Diverge: one commit upstream, one in the clone.
bump "$TMP/origin" upstream
bump "$TMP/clone" local
PRE="$(git -C "$TMP/clone" rev-parse HEAD)"

run setup --repo "$TMP/clone" --db "$TMP/clone-store.db"
check "pull: setup installs the hook" \
    "$([ -x "$TMP/clone/.git/hooks/post-merge" ] && echo yes)" "yes"

rm -f "$SCRATCH/pull.log" "$SCRATCH/cli5.log"
env -u XDG_STATE_HOME -u XDG_CONFIG_HOME HOME="$HOME_DIR" \
    PATH="$FAKE5:/usr/bin:/bin" SKILL_LOG_DB="$TMP/clone-store.db" \
    git -C "$TMP/clone" pull -q \
    >"$SCRATCH/pull.out" 2>"$SCRATCH/pull.err"
check "pull: keeps its exit status with a failing CLI" "$?" "0"
check_absent "pull: the hook leaks no stderr of its own" \
    "$(cat "$SCRATCH/pull.err")" "an older skill-log"
check "pull: the hook passed the pre-merge position" \
    "$(cat "$SCRATCH/cli5.log")" \
    "failing:resolve-merged --since $PRE --quiet"

# An absent CLI: same promise. The controlled PATH holds git and a
# failing mise, and the scratch HOME holds no shims.
git clone -q "$TMP/origin" "$TMP/clone2" 2>/dev/null
git -C "$TMP/clone2" config user.email test@example.com
git -C "$TMP/clone2" config user.name test
git -C "$TMP/clone2" config commit.gpgsign false
git -C "$TMP/clone2" config pull.rebase false
git -C "$TMP/clone2" config pull.ff false
bump "$TMP/clone2" local2

run setup --repo "$TMP/clone2" --db "$TMP/clone2-store.db"
check "pull: setup installs the second hook" \
    "$([ -x "$TMP/clone2/.git/hooks/post-merge" ] && echo yes)" "yes"

FAKE6="$SCRATCH/fake6"
mkdir -p "$FAKE6"
ln -s "$GIT_BIN" "$FAKE6/git"
printf '#!/bin/sh\nexit 1\n' >"$FAKE6/mise"
chmod +x "$FAKE6/mise"

env -u XDG_STATE_HOME -u XDG_CONFIG_HOME HOME="$HOME_DIR" \
    PATH="$FAKE6" SKILL_LOG_DB="$TMP/clone2-store.db" \
    git -C "$TMP/clone2" pull -q \
    >"$SCRATCH/pull2.out" 2>"$SCRATCH/pull2.err"
check "pull: keeps its exit status with an absent CLI" "$?" "0"

# ---------------------------------------------------------- worktree
#
# The hook goes into the repository's common hooks directory, never the
# worktree's own.

make_repo "$TMP/wtmain"
git -C "$TMP/wtmain" worktree add -q -b wtbranch "$TMP/wtlink"
run setup --repo "$TMP/wtlink" --db "$TMP/wtlink-store.db"
check "worktree: setup exits 0" "$STATUS" "0"
if [ -x "$TMP/wtmain/.git/hooks/post-merge" ]; then
    pass "worktree: the hook lands in the common hooks directory"
else
    fail "worktree: the hook lands in the common hooks directory"
fi
if [ -e "$TMP/wtmain/.git/worktrees/wtlink/hooks/post-merge" ]; then
    fail "worktree: no hook in the worktree's own git directory"
else
    pass "worktree: no hook in the worktree's own git directory"
fi
if [ -f "$TMP/wtlink/.skill-log/reports/README.md" ]; then
    pass "worktree: the report directory lands in the checkout"
else
    fail "worktree: the report directory lands in the checkout"
fi

# -------------------------------------------------------------- skills
#
# The skills verdict is the document classification over --skills-dir.

mkdir -p "$TMP/skills/demo"
printf 'a skill\n' >"$TMP/skills/demo/SKILL.md"
run setup --repo "$TMP/r1" --skills-dir "$TMP/skills" --check
check "skills: an unadopted skill is drift" \
    "$(status_of "$OUT" skills)" "drift"
check_contains "skills: the drift names the skill and its state" \
    "$(detail_of "$OUT" skills)" "demo:missing"
check "skills: drift exits 1" "$STATUS" "1"

mkdir -p "$TMP/skills-empty"
run setup --repo "$TMP/r1" --skills-dir "$TMP/skills-empty" --check
check "skills: an empty directory is skipped" \
    "$(status_of "$OUT" skills)" "skipped"
check_contains "skills: the empty skip is named" \
    "$(detail_of "$OUT" skills)" "no skills in"

run setup --repo "$TMP/r1" --skills-dir "$TMP/skills-absent" --check
check "skills: a missing directory is skipped" \
    "$(status_of "$OUT" skills)" "skipped"
check_contains "skills: the missing skip is named" \
    "$(detail_of "$OUT" skills)" "is not a directory"

# --------------------------------------------------------- store refusals
#
# A store that is not this schema is named and left exactly as found:
# setup never migrates.

make_repo "$TMP/rref"
sqlite3 "$TMP/foreign.db" "CREATE TABLE other (x)"
cp "$TMP/foreign.db" "$SCRATCH/foreign.db.before"
run setup --repo "$TMP/rref" --db "$TMP/foreign.db"
check "a foreign store exits 1" "$STATUS" "1"
check_contains "a foreign store is named" "$ERR" "foreign store"
check_one_line "a foreign store is one stderr line" "$ERR"
if cmp -s "$TMP/foreign.db" "$SCRATCH/foreign.db.before"; then
    pass "a foreign store is untouched"
else
    fail "a foreign store is untouched"
fi

printf 'not a database\n' >"$TMP/damaged.db"
cp "$TMP/damaged.db" "$SCRATCH/damaged.db.before"
run setup --repo "$TMP/rref" --db "$TMP/damaged.db"
check "a damaged store exits 1" "$STATUS" "1"
check_contains "a damaged store is named" "$ERR" "damaged store"
if cmp -s "$TMP/damaged.db" "$SCRATCH/damaged.db.before"; then
    pass "a damaged store is untouched"
else
    fail "a damaged store is untouched"
fi

# ------------------------------------------------------------- usage
#
# Every help level ends with 2 to 4 real invocations, and a usage error
# exits 2.

run setup --help
check "help exits 0" "$STATUS" "0"
check_contains "help prints the usage" "$OUT" "usage:"
EX="$(printf '%s\n' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')"
if [ "$EX" -ge 2 ] && [ "$EX" -le 4 ]; then
    pass "help prints 2 to 4 real invocations ($EX)"
else
    fail "help prints 2 to 4 real invocations (got $EX)"
fi

run setup --bogus
check "an unknown flag exits 2" "$STATUS" "2"
check_contains "an unknown flag is named" "$ERR" "unknown option"

run setup --check --remove-hook
check "--check with --remove-hook exits 2" "$STATUS" "2"

run setup --remove-hook --no-hook
check "--remove-hook with --no-hook exits 2" "$STATUS" "2"

run setup --repo
check "a missing value exits 2" "$STATUS" "2"
check_contains "a missing value names the flag" "$ERR" "--repo"

# ------------------------------------------------------------------ done

tally
