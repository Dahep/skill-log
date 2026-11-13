#!/usr/bin/env bash
# Build the release-shaped artifact: one static binary.
#
#   scripts/build.sh
#
# The artifact runs on a machine with no Go toolchain and no system SQLite:
# the SQLite implementation is pure Go, so there is nothing to bundle beside
# the executable.
#
#   dist/skill-log          the executable
#
# The version is baked in at build time from SKILL_LOG_VERSION, else
# `git describe --tags`, else 0.0.0-dev. It is written into the binary with
# -ldflags, never into the checkout.
#
# Only the Go packages under cmd/ and internal/ are built. The reference/
# area is the verbatim report-era implementation kept as the parity ground
# truth: it is never built, never staged and never shipped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DIST="$ROOT/dist"

log() { printf '==> %s\n' "$*"; }

die() {
    printf 'build.sh: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------- version

resolve_version() {
    if [ -n "${SKILL_LOG_VERSION:-}" ]; then
        printf '%s' "$SKILL_LOG_VERSION"
        return
    fi
    local described
    # `git describe --tags` and nothing else: SPEC §8 names the two
    # fallbacks (`git describe --tags`, else 0.0.0-dev), and a `-dirty`
    # suffix is a version the release grammar rejects.
    if described="$(git -C "$ROOT" describe --tags 2>/dev/null)" &&
        [ -n "$described" ]; then
        printf '%s' "$described"
        return
    fi
    printf '0.0.0-dev'
}

VERSION="$(resolve_version)"

# ------------------------------------------------------------------ build

command -v go >/dev/null 2>&1 || die "go is not on PATH (mise install)"

log "version $VERSION"

rm -rf "$DIST"
mkdir -p "$DIST"

(
    cd "$ROOT"
    CGO_ENABLED=0 go build \
        -trimpath \
        -ldflags "-s -w -X github.com/Dahep/skill-log/internal/cli.version=$VERSION" \
        -o "$DIST/skill-log" ./cmd/skill-log
)

log "staged:"
log "  $DIST/skill-log"
