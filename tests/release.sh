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

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

if [ ! -f "$WORKFLOW" ]; then
    printf 'release.sh: %s is missing\n' "$WORKFLOW" >&2
    exit 1
fi

# The lines of the workflow that are the body of a `run:` block: the
# shell source a GitHub expression would be interpolated into.
#
# A `run:` is shell source in every shape the workflow file uses:
#
#   run: |            a block, whose body is the following lines
#   run: >            a block, folded the same way
#   run: |-           a block, with the trailing newline stripped
#   run: some command  a one-liner
#
# The block body ends at the next key of the same mapping — a line that
# starts with a key and a colon at the step's indentation — or at the
# end of the file. Every shape contributes its shell source, so a
# `run:` body that carries an expression cannot hide behind a block
# scalar marker.
run_lines() {
    awk '
        # A `run:` with a block scalar or a one-line body: the shell
        # source starts here.
        /^[[:space:]]*run:[[:space:]]*(\||>|\|-|>-|>\|)?[[:space:]]*$/ {
            inrun = 1
            next
        }
        /^[[:space:]]*run:[[:space:]]*\S/ {
            # A one-line `run:` is shell source too.
            print
            next
        }
        inrun {
            # A new key of the mapping ends the block body.
            if ($0 ~ /^[[:space:]]*[-a-zA-Z_][-a-zA-Z0-9_]*:[[:space:]]*/) { inrun = 0; next }
            print
        }
    ' "$1"
}

# The shell source that carries a GitHub expression. An expression
# there is text the shell parses, so a value the workflow did not
# write becomes shell source.
#
# The pattern is a literal: a GitHub expression, written as text.
# shellcheck disable=SC2016  # the expression is the text being looked for
interpolated_in() {
    run_lines "$1" | grep -nF '${{' || true
}

interpolated="$(interpolated_in "$WORKFLOW")"
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
#
# A `uses:` line carries a trailing comment in this workflow
# (`uses: actions/checkout@<sha>  # v4`), so the ref is the first
# whitespace-delimited word after the `@` — the comment is not part of
# the pin. Only a full 40-hex commit SHA passes; a tag, a branch or a
# short SHA is reported.
unpinned_uses() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line !~ /^uses:/) { next }
            sub(/^uses:[[:space:]]*/, "", line)
            # A YAML comment at the end of the line is not the pin.
            sub(/[[:space:]]+#.*$/, "", line)
            sub(/[[:space:]]*$/, "", line)
            at = index(line, "@")
            if (at == 0 || at == 1) {
                print $0
                next
            }
            ref = substr(line, at + 1)
            if (ref ~ /[[:space:]]/) {
                print $0
                next
            }
            if (ref !~ /^[0-9a-f]{40}$/) { print $0 }
        }
    ' "$1"
}

UNPINNED="$(unpinned_uses "$WORKFLOW")"
if [ -n "$UNPINNED" ]; then
    fail "a third-party action is pinned to a tag, not a commit"
    printf '     %s\n' "$UNPINNED"
else
    pass "every third-party action is pinned to a commit"
fi

# Every `uses:` names a version at all, and the pinned ones are SHAs.
check_contains "the checkout action is pinned" \
    "$(cat "$WORKFLOW")" "actions/checkout@"

# ------------------------------------------------- the guards can fail
#
# A guard that cannot fail is not a guard. Both detectors are fed a
# synthetic workflow that carries the defect they look for, and each
# must report it: the interpolation detector on an expression inside a
# `run:` body, and the pin detector on a tag-pinned action.
#
# The synthetic text is a heredoc, so the case exercises the same
# parsing path the real workflow goes through. The real checks above
# are not weakened by it: they still read the real workflow file.

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

SYNTH="$SCRATCH/synthetic-workflow.yml"
cat >"$SYNTH" <<'SYNTHETIC'
name: "synthetic"
on:
  push:
    tags:
      - "v*"
jobs:
  build:
    runs-on: ubuntu-22.04
    steps:
      - name: "Checkout"
        uses: actions/checkout@v4
      - name: "Do the thing"
        env:
          TAG_NAME: ${{ github.ref_name }}
        run: |
          echo "${{ github.ref_name }}"
SYNTHETIC

# The interpolation detector must report the synthetic expression.
if [ -n "$(interpolated_in "$SYNTH")" ]; then
    pass "the interpolation guard reports an expression inside a run: body"
else
    fail "the interpolation guard reports an expression inside a run: body"
fi

# The pin detector must report the synthetic tag-pinned action.
if [ -n "$(unpinned_uses "$SYNTH")" ]; then
    pass "the pin guard reports a tag-pinned action"
else
    fail "the pin guard reports a tag-pinned action"
fi

# Each `run:` shape contributes its shell source. A guard that only
# understands one shape would pass the others vacuously; these cases
# pin each shape down.

literal="$SCRATCH/literal.yml"
cat >"$literal" <<'LITERAL'
jobs:
  build:
    steps:
      - name: "Literal"
        run: |
          echo "${{ github.ref_name }}"
LITERAL
if [ -n "$(interpolated_in "$literal")" ]; then
    pass "a run: | block is scanned for an expression"
else
    fail "a run: | block is scanned for an expression"
fi
one_line="$SCRATCH/one-line.yml"
cat >"$one_line" <<'ONELINE'
jobs:
  build:
    steps:
      - name: "One liner"
        run: echo "${{ github.ref_name }}"
ONELINE
if [ -n "$(interpolated_in "$one_line")" ]; then
    pass "a one-line run: is scanned for an expression"
else
    fail "a one-line run: is scanned for an expression"
fi

folded="$SCRATCH/folded.yml"
cat >"$folded" <<'FOLDED'
jobs:
  build:
    steps:
      - name: "Folded"
        run: >
          echo "${{ github.ref_name }}"
FOLDED
if [ -n "$(interpolated_in "$folded")" ]; then
    pass "a folded run: is scanned for an expression"
else
    fail "a folded run: is scanned for an expression"
fi

stripped="$SCRATCH/stripped.yml"
cat >"$stripped" <<'STRIPPED'
jobs:
  build:
    steps:
      - name: "Stripped"
        run: |-
          echo "${{ github.ref_name }}"
STRIPPED
if [ -n "$(interpolated_in "$stripped")" ]; then
    pass "a run: |- is scanned for an expression"
else
    fail "a run: |- is scanned for an expression"
fi

# A clean `run:` body is not reported: the expression in the `env:`
# entry beside it is the environment, which is where a version belongs.
clean="$SCRATCH/clean.yml"
cat >"$clean" <<'CLEAN'
jobs:
  build:
    steps:
      - name: "Clean"
        env:
          TAG_NAME: ${{ github.ref_name }}
        run: |
          echo "$TAG_NAME"
CLEAN
if [ -z "$(interpolated_in "$clean")" ]; then
    pass "an expression in an env: entry is not a run: body"
else
    fail "an expression in an env: entry is not a run: body"
fi

# A comment after the pin is not the pin: a full SHA with a trailing
# comment passes, a tag with a trailing comment does not.
sha_with_comment="$SCRATCH/sha-with-comment.yml"
cat >"$sha_with_comment" <<'SHACOMMENT'
jobs:
  build:
    steps:
      - name: "Checkout"
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4
SHACOMMENT
if [ -z "$(unpinned_uses "$sha_with_comment")" ]; then
    pass "a SHA pin with a trailing comment passes"
else
    fail "a SHA pin with a trailing comment passes"
fi

tag_with_comment="$SCRATCH/tag-with-comment.yml"
cat >"$tag_with_comment" <<'TAGCOMMENT'
jobs:
  build:
    steps:
      - name: "Checkout"
        uses: actions/checkout@v4  # v4
TAGCOMMENT
if [ -n "$(unpinned_uses "$tag_with_comment")" ]; then
    pass "a tag pin with a trailing comment is reported"
else
    fail "a tag pin with a trailing comment is reported"
fi

# A short SHA is not a commit SHA either.
short_sha="$SCRATCH/short-sha.yml"
cat >"$short_sha" <<'SHORTSHA'
jobs:
  build:
    steps:
      - name: "Checkout"
        uses: actions/checkout@11d5960
SHORTSHA
if [ -n "$(unpinned_uses "$short_sha")" ]; then
    pass "a short SHA pin is reported"
else
    fail "a short SHA pin is reported"
fi

tally
