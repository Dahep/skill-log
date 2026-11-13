#!/usr/bin/env bash
# Builds the static release artifact at dist/skill-log.
# Run: scripts/build.sh
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
    # A `-dirty` suffix is a version the release grammar rejects.
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
