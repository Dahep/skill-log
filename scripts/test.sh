#!/usr/bin/env bash
# Run every test suite against the built artifact.
#
#   scripts/test.sh            # run the suites
#   scripts/test.sh --build    # build first, then run them
#
# The suites are black-box: they exercise `dist/skill-log` as a process,
# with a scratch HOME and a scratch store, so they need the artifact from
# `scripts/build.sh` (this script's `--build` runs it).
#
# Each suite is independent and prints its own report; this script prints
# one line per suite and exits non-zero if any of them failed, so a single
# command answers "does the tree still work".
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
for suite in smoke store context show stats report resolve skills; do
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
