#!/usr/bin/env bash
# Release suite: verifies workflow pinning and safe version interpolation.
# Run: tests/release.sh
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

interpolated_in() {
    # shellcheck disable=SC2016  # the expression is literal text
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
