#!/usr/bin/env bash
# The release workflow test: the shape of the release pipeline.
#
#   tests/release.sh
#
# The workflow is the one place where a version read from a git tag
# reaches a shell. A tag is a name a machine's owner chose, and a name
# that reaches `run:` as shell source is executed: a tag named
# `v$(id)` runs a command. So the version must reach the shell through
# the environment, never through the interpolated text of a `run:`
# block, and its grammar must be checked before anything uses it.
#
# The third-party actions are pinned to commit SHAs for the same
# reason: a tag is a name somebody else can move.
#
# This is a test of the workflow file, which is the artifact here: the
# release pipeline has no other seam.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release.yml"

# shellcheck shell=bash
. "$HERE/lib.sh"

if [ ! -f "$WORKFLOW" ]; then
    printf 'release.sh: %s is missing\n' "$WORKFLOW" >&2
    exit 1
fi

# The lines of the workflow that are the body of a `run:` block: the
# shell source a GitHub expression would be interpolated into.
run_lines() {
    awk '
        /^[[:space:]]*run:[[:space:]]*$/ { inrun = 1; next }
        /^[[:space:]]*run:[[:space:]]*/ {
            # A one-line `run:` is shell source too.
            print
            next
        }
        inrun {
            if ($0 ~ /^[[:space:]]*[-a-zA-Z_]+:/) { inrun = 0; next }
            print
        }
    ' "$WORKFLOW"
}

# The shell source that carries a GitHub expression. An expression
# there is text the shell parses, so a value the workflow did not
# write becomes shell source.
# The pattern is a literal: a GitHub expression, written as text.
# shellcheck disable=SC2016  # the expression is the text being looked for
interpolated="$(run_lines | grep -nF '${{' || true)"
if [ -n "$interpolated" ]; then
    fail "the run: blocks interpolate a GitHub expression into shell source"
    printf '     %s\n' "$interpolated"
else
    pass "the run: blocks interpolate no GitHub expression into shell source"
fi

# The version reaches the shell through the environment: the tag is
# read into an env: entry, and the shell reads it from there.
check_contains "the tag reaches the shell through the environment" \
    "$(cat "$WORKFLOW")" "TAG_NAME: \${{ github.ref_name }}"
check_contains "the version reaches the package step through the environment" \
    "$(cat "$WORKFLOW")" "SKILL_LOG_VERSION: \${{ steps.version.outputs.version }}"

# The grammar is checked: a strict vX.Y.Z, before anything uses it.
check_contains "the workflow validates the version grammar" \
    "$(cat "$WORKFLOW")" "v[0-9]*.[0-9]*.[0-9]*"

# The third-party actions are pinned to commit SHAs: a tag is a name
# somebody else can move.
UNPINNED="$(grep -E '^[[:space:]]*uses:[[:space:]]*[^[:space:]]+@[^[:space:]]*$' \
    "$WORKFLOW" || true)"
if [ -n "$UNPINNED" ]; then
    fail "a third-party action is pinned to a tag, not a commit"
    printf '     %s\n' "$UNPINNED"
else
    pass "every third-party action is pinned to a commit"
fi

# Every `uses:` names a version at all, and the pinned ones are SHAs.
check_contains "the checkout action is pinned" \
    "$(cat "$WORKFLOW")" "actions/checkout@"

tally
