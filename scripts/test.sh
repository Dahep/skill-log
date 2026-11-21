#!/usr/bin/env bash
# Runs every acceptance suite against dist/skill-log.
# Run: scripts/test.sh [--build]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ "${1:-}" = "--build" ]; then
    "$HERE/build.sh" || exit 1
fi

if [ ! -x "$ROOT/dist/skill-log" ]; then
    printf 'test.sh: %s/dist/skill-log is missing; run scripts/build.sh (or pass --build)\n' \
        "$ROOT" >&2
    exit 1
fi

FAILED=0

for suite in smoke store context show stats report resolve merged skills setup release sqlite contract; do

    printf '\n== %s\n' "$suite"
    if bash "$ROOT/tests/$suite.sh"; then
        printf '== %s: ok\n' "$suite"
    else
        printf '== %s: FAILED\n' "$suite"
        FAILED=1
    fi
done

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    printf 'test.sh: at least one suite failed\n' >&2
    exit 1
fi
printf 'test.sh: every suite passed\n'
