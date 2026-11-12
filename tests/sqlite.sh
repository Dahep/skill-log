#!/usr/bin/env bash
# The SQLite test: the store's SQLite travels inside the binary.
#
#   tests/sqlite.sh
#
# The release ships one statically linked executable. The SQLite it uses
# is a pure-Go implementation compiled into that executable, so the store
# needs no library on the machine it runs on — and the machine it runs on
# need not have a SQLite at all.
#
# This suite proves that, at the seam the contract names: the artifact as
# a process, with no system SQLite anywhere in reach. A write, a read and
# a resolve all go through the store, so all three succeeding is the
# round-trip that says the store works where no SQLite is installed.
#
# The environment without a system SQLite is a bubblewrap root that holds
# the executable and nothing else: no /usr/lib, no loader, no SQLite, no
# toolchain. bwrap is used rather than a container: no daemon, no cgroup
# namespace, no privileges, and the desktop's live session cgroups are
# never touched. Where bwrap is missing, the suite falls back to an empty
# environment (env -i), which proves the binary needs no environment of
# the developer's machine at all but cannot rule out a library found
# through the loader's default path; that case says so rather than
# pretending.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(dirname "$HERE")" && pwd)"
DIST="$ROOT/dist"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-sqlite}"

# shellcheck shell=bash
# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

if [ ! -x "$DIST/skill-log" ]; then
    printf 'sqlite.sh: %s/skill-log is missing; run scripts/build.sh first\n' \
        "$DIST" >&2
    exit 1
fi

# The artifact is static: there is no shared object for the loader to
# find, so the SQLite that reaches the store is the one inside the
# executable.
if command -v ldd >/dev/null 2>&1; then
    ldd_report="$(ldd "$DIST/skill-log" 2>&1 || true)"
    if printf '%s\n' "$ldd_report" | grep -qi 'not a dynamic executable'; then
        pass "the artifact is a static executable"
    else
        fail "the artifact is a static executable ($ldd_report)"
    fi
else
    if file "$DIST/skill-log" 2>/dev/null | grep -qi 'statically linked'; then
        pass "the artifact is a static executable"
    else
        fail "the artifact is a static executable"
    fi
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

# ------------------------------------------------- the environment
#
# Two shapes, strongest first. The first one that exists is the one the
# round-trip runs in.

SANDBOX_HOME="$SCRATCH/home"
mkdir -p "$SANDBOX_HOME"

SANDBOX_ROOT=""
ENVIRONMENT=""

# The sandbox is used only when bwrap actually works: a bwrap on the PATH
# that cannot create a namespace is not a sandbox, and a case that ran
# in it would prove nothing.
if command -v bwrap >/dev/null 2>&1 &&
    bwrap --ro-bind / / --dev /dev --unshare-all true >/dev/null 2>&1; then
    # A root with no system libraries at all: no /usr/lib, no loader
    # cache, no SQLite, no toolchain. The static artifact needs none of
    # them, and a root that carried a copy of /usr/lib would put a
    # system SQLite back within its reach — which is exactly what this
    # case exists to rule out.
    SANDBOX_ROOT="$SCRATCH/root"
    sandbox_root "$SANDBOX_ROOT" "$DIST/skill-log"
    ENVIRONMENT="bubblewrap"
else
    # No bwrap: an empty environment. It proves the binary needs no
    # environment of the developer's machine, but the loader's default
    # path is still the host's, so a system SQLite cannot be ruled out.
    ENVIRONMENT="env -i"
fi

printf 'environment: %s\n' "$ENVIRONMENT"

# run <args...>: the artifact in the environment, with a scratch store.
#
# Every run's stderr is kept: the point of the suite is that no run
# anywhere reported a missing or unusable SQLite.
run() {
    local out err
    out="$SCRATCH/out"
    err="$SCRATCH/err"
    if [ "$ENVIRONMENT" = "bubblewrap" ]; then
        sandbox_run "$SANDBOX_ROOT" "$SANDBOX_HOME" /pkg/skill-log "$@" \
            >"$out" 2>"$err"
    else
        env -i HOME="$SANDBOX_HOME" PATH=/usr/bin:/bin \
            "$DIST/skill-log" "$@" >"$out" 2>"$err"
    fi
    STATUS=$?
    OUT="$(cat "$out")"
    ERR="$(cat "$err")"
    printf '%s\n' "$ERR" >>"$SCRATCH/all-err"
}

# The round-trip: a write, a read and a resolve, all through the store,
# in an environment with no system SQLite.
run add --skill alpha
check "a write exits 0" "$STATUS" "0"
check "a write prints the marker" "$OUT" "$(hostname)#1"
check "a write prints nothing on stderr" \
    "$(wc -c < "$SCRATCH/err" | tr -d ' ')" "0"

run show --json
check "a read exits 0" "$STATUS" "0"
check "a read reads the row back" "$(json_field "$OUT" skill)" "alpha"
check "the row carries a local ISO 8601 stamp with an offset" \
    "$(printf '%s' "$OUT" | python3 -c '
import json, re, sys
row = json.loads(sys.stdin.read())
print("yes" if re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$", row.get("ts", "")) else "no")
')" "yes"

run resolve --id 1 --fix abc1234
check "a resolve exits 0" "$STATUS" "0"
check "a resolve prints the marker it stamped" \
    "$(printf '%s' "$OUT" | grep -c ' resolved: abc1234')" "1"

run show --json
check "the resolved row carries the fix" "$(json_field "$OUT" fix)" "abc1234"
check "the resolved row carries a resolution stamp" \
    "$(printf '%s' "$OUT" | python3 -c '
import json, re, sys
row = json.loads(sys.stdin.read())
print("yes" if re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$", row.get("resolved_at", "")) else "no")
')" "yes"

# The point of the suite: nothing anywhere said the SQLite was missing.
# The store's SQLite travels inside the binary, so no run can report a
# missing or unusable library.
check "no run reported a SQLite problem" \
    "$(grep -ci 'sqlite unavailable\|cannot load\|shared object' "$SCRATCH/all-err")" "0"

# The store is a real SQLite file: the schema the tool wrote is there,
# read through an ordinary SQLite reader.
DB="$SANDBOX_HOME/.local/state/skill-log/skills.db"
if command -v sqlite3 >/dev/null 2>&1; then
    check "the store is a SQLite database" \
        "$(sqlite3 "$DB" 'pragma journal_mode' 2>/dev/null)" "wal"
    check "the row is in the invocations table" \
        "$(sqlite3 "$DB" "select count(*) from invocations where skill = 'alpha'" 2>/dev/null)" "1"
else
    printf 'skip sqlite3 is not installed: the store file was not read directly\n'
fi

# The environment itself: the case is only worth anything if there really
# is no system SQLite inside it.
if [ "$ENVIRONMENT" = "bubblewrap" ]; then
    check "the sandbox root carries no SQLite library" \
        "$(find "$SANDBOX_ROOT" -name 'libsqlite3*' 2>/dev/null | wc -l | tr -d ' ')" "0"
    check "the sandbox root carries no library directory" \
        "$([ -d "$SANDBOX_ROOT/usr/lib" ] && printf yes || printf no)" "no"
    check "the sandbox root carries no Go toolchain" \
        "$(find "$SANDBOX_ROOT/usr/bin" -maxdepth 1 \
            \( -name go -o -name mojo -o -name gcc \) 2>/dev/null | wc -l | tr -d ' ')" "0"
else
    printf 'skip bwrap is not installed: the environment cannot rule out a system SQLite\n'
fi

tally
