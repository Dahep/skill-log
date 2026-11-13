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

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-release}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

# shellcheck shell=bash
# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

if [ ! -f "$WORKFLOW" ]; then
    printf 'release.sh: %s is missing\n' "$WORKFLOW" >&2
    exit 1
fi

# The lines of the workflow that are the body of a `run:` block: the
# shell source a GitHub expression would be interpolated into.
#
# The block form is not one spelling. A step's `run:` may be a plain
# key (`run: |`) or a list item (`- run: |`), and the block indicator
# may carry a comment (`run: | # why`). The scanner has to enter block
# mode on all of them: a workflow whose blocks use one of the other
# spellings was invisible to the scan, so an expression in a block body
# passed.
#
# The body of a block is the lines indented *more* than the key that
# opened it, so the scanner tracks the indentation of the `run:` it
# entered on rather than looking for the next key: a body may hold a
# line that looks like a key, and the keys of the step that owns the
# run are indented deeper than the step.
#
# The scanner takes the workflow to read as its argument, so the
# mutation case below can point it at a workflow of its own.
run_lines() {
    awk '
        function indent_of(line,   i) {
            i = 1
            while (i <= length(line) && substr(line, i, 1) == " ") {
                i++
            }
            return i - 1
        }

        # The value of the `run:` key of a step, in either spelling: a
        # plain key or a list item. The value after the key is what says
        # which form it is; an empty answer means the line is not a run.
        function run_value(line,   stripped, rest) {
            stripped = line
            sub(/^[[:space:]]*/, "", stripped)
            if (substr(stripped, 1, 1) == "-") {
                sub(/^-[[:space:]]*/, "", stripped)
            }
            if (stripped !~ /^run:/) {
                return ""
            }
            rest = stripped
            sub(/^run:[[:space:]]*/, "", rest)
            return rest
        }

        inrun {
            # The body ends at the first line that is not indented more
            # than the key that opened it. A line in the body that looks
            # like a key is still a line in the body.
            bodyindent = indent_of($0)
            if ($0 ~ /^[[:space:]]*$/ || bodyindent > runindent) {
                print
                next
            }
            inrun = 0
        }

        {
            value = run_value($0)
            if (value == "") {
                next
            }
            # A block form: `run: |`, `run: >`, with an optional
            # chomping indicator and an optional comment after it. The
            # body is the lines indented more than the key.
            if (value ~ /^[|>][-+0-9]*[[:space:]]*([#].*)?$/) {
                inrun = 1
                runindent = indent_of($0)
                next
            }
            # A bare `run:` with the body indented under it.
            if (value ~ /^$/) {
                inrun = 1
                runindent = indent_of($0)
                next
            }
            # A one-line `run:` is shell source too.
            print
        }
    ' "${1:-$WORKFLOW}"
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

# ------------------------------------------------- the scanner sees the bodies
#
# The scan above is only as good as the scanner behind it: a scanner
# that sees no block body at all finds no expression in one, and the
# suite passes on a workflow that interpolates everywhere. So the
# scanner is proved on a workflow of its own: the same block shape, with
# an expression in the body, must be found.
#
# The mutation is the test: re-inject the expression into a real block
# body, and the scan must fail. A scanner that cannot see the body
# cannot fail, and the suite would pass on the mutation.
MUTANT="$SCRATCH/mutant.yml"
mkdir -p "$SCRATCH"
# The mutation: the version's own assignment inside a `run: |` block
# body becomes an expression, the way a careless edit would write it.
sed 's|version="\$TAG_NAME"|version="${{ github.ref_name }}"|' \
    "$WORKFLOW" > "$MUTANT"
if [ ! -s "$MUTANT" ]; then
    fail "the mutation could not be written"
else
    # The mutation really did put an expression into a block body.
    # The pattern is a literal: a GitHub expression, written as text.
    # shellcheck disable=SC2016  # the expression is the text being looked for
    check_contains "the mutation put an expression into a block body" \
        "$(cat "$MUTANT")" 'version="${{ github.ref_name }}"'
    # And the scanner finds it.
    # shellcheck disable=SC2016  # the expression is the text being looked for
    if run_lines "$MUTANT" | grep -qF '${{'; then
        pass "the scanner sees an expression in a block body"
    else
        fail "the scanner does not see an expression in a block body"
    fi
fi

# ------------------------------------- the scanner sees every block form
#
# The block form is not one spelling. A step's `run:` may be written as
# a plain key or as a list item (`- run: |`), and the block indicator
# may carry a comment (`run: | # why`). A scanner that recognises only
# one spelling sees no body in the others, and a workflow that uses them
# passes the scan with an expression in its shell source.
#
# Each form is mutation-tested on a workflow of its own: an expression
# inside a body the scanner must see, and the scanner must find it.
#
# The scanner takes the workflow to read as its argument, so each case
# points it at its own file.
for form in list comment; do
    case "$form" in
    list)
        # The list-item form: the step's key carries the item's dash.
        FORM_YML="$SCRATCH/form-list.yml"
        cat > "$FORM_YML" <<'FORM'
name: form
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: a list-item step
        - run: |
            echo "made up"
FORM
        ;;
    comment)
        # The comment form: the block indicator carries a comment.
        FORM_YML="$SCRATCH/form-comment.yml"
        cat > "$FORM_YML" <<'FORM'
name: form
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: a commented step
        run: | # why this step runs
          echo "made up"
FORM
        ;;
    esac

    # The mutation: the body of the block gets an expression.
    # shellcheck disable=SC2016  # the expression is the text being looked for
    sed 's|echo "made up"|echo "${{ github.ref_name }}"|' \
        "$FORM_YML" > "$FORM_YML.mutant"

    # The mutation really did put an expression into the block body.
    # shellcheck disable=SC2016  # the expression is the text being looked for
    if ! grep -qF '${{' "$FORM_YML.mutant"; then
        fail "the $form mutation could not be written"
    elif ! run_lines "$FORM_YML.mutant" | grep -qF '${{'; then
        fail "the scanner does not see an expression in a $form block body"
    else
        pass "the scanner sees an expression in a $form block body"
    fi
done

tally
