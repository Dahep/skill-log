#!/usr/bin/env bash
# The shared harness for the test scripts. Sourced, never run.
#
#   . "$HERE/lib.sh"
#
# One assertion vocabulary for every suite. The three suites had drifted
# into three copies of `check`, one of them documenting a signature its
# body did not have, and no suite had a JSON reader that could survive a
# value the writer escapes. Both live here now.
#
# shellcheck shell=bash

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

# check <name> <actual> <expected>
check() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

# check_contains <name> <actual> <needle>
check_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (expected to contain '$3', got '$2')" ;;
    esac
}

# check_absent <name> <actual> <needle>
check_absent() {
    case "$2" in
        *"$3"*) fail "$1 (expected not to contain '$3', got '$2')" ;;
        *) pass "$1" ;;
    esac
}

# check_one_line <name> <text>
#
# A diagnostic is exactly one line. Counting non-empty lines is the
# assertion: a message that grew a newline reports two.
check_one_line() {
    if [ "$(printf '%s\n' "$2" | grep -c .)" = "1" ]; then
        pass "$1"
    else
        fail "$1 (expected one line, got: $2)"
    fi
}

# require_tools <tool>...
#
# A suite that cannot run must say so and stop, rather than compare the
# empty output of a missing command against empty.
require_tools() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf '%s: %s is required\n' "$0" "$tool" >&2
            exit 1
        fi
    done
}

# sandbox_root <root> <binary>...
#
# Build a minimal bubblewrap root that holds the given executables and
# nothing else: no /usr/lib, no /lib, no ld.so cache, no SQLite, no
# toolchain.
#
# The artifact is statically linked, so it needs none of the host's
# libraries to run — which is the whole point of the root. A root that
# carried a copy of /usr/lib would be eleven gigabytes and would put a
# system SQLite back within the binary's reach, which is exactly what
# these cases exist to rule out.
#
# No helper binary is copied in: the host's own tools are dynamically
# linked and would not run in a root without libraries, so the cases read
# the root from the outside instead.
sandbox_root() {
    local root="$1"
    shift
    rm -rf "$root"
    mkdir -p "$root/usr/bin" "$root/etc" "$root/dev" "$root/proc" \
        "$root/pkg" "$root/tmp"
    chmod 1777 "$root" "$root/tmp"

    local binary name
    for binary in "$@"; do
        name="$(basename "$binary")"
        cp -a "$binary" "$root/pkg/$name"
    done
}

# sandbox_run <root> <scratch-home> <args...>
#
# Run a command in the sandbox root: read-only, no network, no
# privileges, and a writable scratch home bound over /tmp so a store can
# be written.
#
# The store environment is cleared: an XDG_STATE_HOME inherited from the
# developer's machine would point the store outside the sandbox, and the
# case would prove nothing about the sandbox at all.
sandbox_run() {
    local root="$1" home="$2"
    shift 2
    bwrap --ro-bind "$root" / --bind /dev /dev --proc /proc --unshare-all \
        --bind "$home" /tmp --die-with-parent \
        --setenv HOME /tmp --setenv PATH /usr/bin:/bin \
        --setenv XDG_STATE_HOME /tmp/.local/state \
        --setenv XDG_CONFIG_HOME /tmp/.config \
        --unsetenv SKILL_LOG_DB \
        "$@"
}

# json_field <json> <key>: one top-level string field.
#
# Read with a real JSON parser, not `sed`. A `sed` expression cannot
# survive the writer's own escaping: a skill named `a"b` comes back
# mangled from one, so the test would be weaker than the code it checks.
json_field() {
    printf '%s' "$1" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.loads(sys.stdin.read()).get(key, "")
except Exception:
    value = ""
print("" if value is None else value)
' "$2"
}

# json_problem <json>: the first problem, as text.
json_problem() {
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    problems = json.loads(sys.stdin.read()).get("problems") or []
except Exception:
    problems = []
print(problems[0] if problems else "")
'
}

# json_array <json> <key>: one top-level array of strings, comma-joined.
#
# Read through a real parser, so an item carrying a quote or a comma is
# still the item the writer emitted.
json_array() {
    printf '%s' "$1" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.loads(sys.stdin.read()).get(key) or []
except Exception:
    value = []
print(",".join(str(item) for item in value))
' "$2"
}

# json_number <json> <key>: one top-level numeric field, as %g.
#
# Numbers are read through a real parser too, and printed in the same
# compact form every case expects: 1.5, 0, 1.33.
json_number() {
    printf '%s' "$1" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.loads(sys.stdin.read()).get(key)
except Exception:
    value = None
print("" if value is None else "%g" % value)
' "$2"
}

# json_keys <json>: the object's keys, sorted, space-separated.
json_keys() {
    printf '%s' "$1" | python3 -c '
import json, sys
print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))
'
}

# hold_lock <db> <ready-file> <seconds>: a second process that holds the
# store's write lock for a while, so a case can prove that a write
# behind a real lock is retried (and that an exhausted budget fails
# quietly). The transaction is never committed while the lock is held.
#
# The lock is held for real: a reader that arrives behind it has to
# wait, which is what the case asserts.
hold_lock() {
    python3 - "$1" "$2" "$3" <<'PY'
import sqlite3
import sys
import time

db = sqlite3.connect(sys.argv[1], timeout=30)
db.execute("BEGIN IMMEDIATE")
db.execute(
    "INSERT INTO invocations (ts, skill, machine) VALUES (?, ?, ?)",
    ("2026-01-01T00:00:00+00:00", "lock-holder", "boxA"),
)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write("ready")
time.sleep(float(sys.argv[3]))
db.rollback()
db.close()
PY
}

# wait_for <file>: wait for a readiness file, up to ten seconds.
#
# The handshake a case needs when it depends on another process being
# ready: the writer says it is, and the case waits for that, instead of
# sleeping and hoping.
wait_for() {
    local n=0
    while [ ! -f "$1" ] && [ "$n" -lt 100 ]; do
        sleep 0.1
        n=$((n + 1))
    done
}

# tally: the report line and the suite's exit status.
tally() {
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}
