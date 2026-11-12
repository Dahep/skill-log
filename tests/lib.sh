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

# json_keys <json>: the object's keys, sorted, space-separated.
json_keys() {
    printf '%s' "$1" | python3 -c '
import json, sys
print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))
'
}

# tally: the report line and the suite's exit status.
tally() {
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}
