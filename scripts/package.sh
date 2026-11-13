#!/usr/bin/env bash
# Builds the versioned release archive and checksum in dist/ or --out.
# Run: scripts/package.sh [--version vX.Y.Z] [--out DIR]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(dirname "$HERE")" && pwd)"

# The release archive target.
TARGET=x86_64-unknown-linux-gnu

log() { printf '==> %s\n' "$*"; }

die() {
    printf 'package.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
usage: scripts/package.sh [--version <vX.Y.Z>] [--out <dir>]

  --version <vX.Y.Z>  the release version (default: SKILL_LOG_VERSION,
                      then git describe --tags)
  --out <dir>         where the archive goes (default: dist/)
EOF
}

VERSION_ARG=""
OUT="$ROOT/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version needs a value"
            VERSION_ARG="$2"
            shift 2
            ;;
        --out)
            [ $# -ge 2 ] || die "--out needs a directory"
            OUT="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

for tool in go tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# ---------------------------------------------------------------- version

if [ -n "$VERSION_ARG" ]; then
    VERSION="$VERSION_ARG"
elif [ -n "${SKILL_LOG_VERSION:-}" ]; then
    VERSION="$SKILL_LOG_VERSION"
else
    VERSION="$(git -C "$ROOT" describe --tags 2>/dev/null || true)"
fi
[ -n "$VERSION" ] ||
    die "no version: pass --version vX.Y.Z or set SKILL_LOG_VERSION"
case "$VERSION" in
    */* | *" "* | *$'\t'*) die "version must not contain a slash or space: $VERSION" ;;
esac

# ------------------------------------------------------------------ build
#
# The archive name states the target, and the toolchain must match it.

TARGET_GOOS=linux
TARGET_GOARCH=amd64

GOARCH_ENV="$(go env GOARCH)"
GOOS_ENV="$(go env GOOS)"
[ "$GOARCH_ENV" = "amd64" ] ||
    die "the archive name says x86_64-unknown-linux-gnu, but this toolchain builds for $GOARCH_ENV"
[ "$GOOS_ENV" = "linux" ] ||
    die "the archive name says x86_64-unknown-linux-gnu, but this toolchain builds for $GOOS_ENV"

GOOS="$TARGET_GOOS" GOARCH="$TARGET_GOARCH" \
    SKILL_LOG_VERSION="$VERSION" "$HERE/build.sh"

# ------------------------------------------------------- the licence material
#
# Third-party notices and licence texts come from the pinned module in the module cache.

MODULE_DIR="$(go list -m -f '{{.Dir}}' modernc.org/sqlite 2>/dev/null || true)"
[ -n "$MODULE_DIR" ] && [ -d "$MODULE_DIR" ] ||
    die "the modernc.org/sqlite module is not in the module cache; run go mod download"

NOTICE="$MODULE_DIR/LICENSE-3RD-PARTY.md"
[ -f "$NOTICE" ] ||
    die "$NOTICE is missing; the module carries no third-party notices"

# Every licence text named by the notices is shipped.
NOTICE_LICENSES=()
for name in LICENSE LICENSE-SQLITE LICENSE-SQLITE_VEC; do
    [ -f "$MODULE_DIR/$name" ] || continue
    NOTICE_LICENSES+=("$name")
done
[ "${#NOTICE_LICENSES[@]}" -gt 0 ] ||
    die "$MODULE_DIR carries no licence text to ship"

# ------------------------------------------------------------ pack + hash

STAGE="$ROOT/dist"
NAME="skill-log-$VERSION-$TARGET.tar.gz"

[ -x "$STAGE/skill-log" ] || die "$STAGE/skill-log is missing after the build"

# The archive is staged in its own directory, so the tarball's entries are
# exactly the shipped names and the root directory never leaks into it.
PACK="$ROOT/.package-stage"
rm -rf "$PACK"
mkdir -p "$PACK/NOTICE-LICENSES"

cp "$STAGE/skill-log" "$PACK/skill-log"
cp "$ROOT/LICENSE" "$PACK/LICENSE"

# Licence paths in the notices are rewritten to their shipped locations.
# shellcheck disable=SC2016  # the backticks are the text being looked for
sed -e 's|\[LICENSE\](LICENSE)|[LICENSE](NOTICE-LICENSES/LICENSE)|' \
    -e 's|`LICENSE-SQLITE_VEC`|`NOTICE-LICENSES/LICENSE-SQLITE_VEC`|g' \
    -e 's|`LICENSE-SQLITE`|`NOTICE-LICENSES/LICENSE-SQLITE`|g' \
    "$NOTICE" >"$PACK/THIRD-PARTY-NOTICES.md"
if grep -qF '[LICENSE](LICENSE)' "$PACK/THIRD-PARTY-NOTICES.md"; then
    die "the third-party notices still link to a licence that is not in the archive"
fi
for name in "${NOTICE_LICENSES[@]}"; do
    cp "$MODULE_DIR/$name" "$PACK/NOTICE-LICENSES/$name"
done

# Every licence path named by the notices resolves inside the archive.
grep -oE 'NOTICE-LICENSES/[A-Za-z0-9._-]+' "$PACK/THIRD-PARTY-NOTICES.md" |
    sort -u >"$PACK/.referenced" || true
while IFS= read -r referenced; do
    [ -n "$referenced" ] || continue
    [ -f "$PACK/$referenced" ] ||
        die "the third-party notices point at $referenced, which the archive does not carry"
done <"$PACK/.referenced"
rm -f "$PACK/.referenced"

# Every shipped licence file is named by the notices.
for name in "${NOTICE_LICENSES[@]}"; do
    grep -qF "NOTICE-LICENSES/$name" "$PACK/THIRD-PARTY-NOTICES.md" ||
        die "the third-party notices no longer name $name"
done

if find "$PACK" -type f -name '*.so*' | grep -q .; then
    die "the staged tree holds a shared object; the archive must carry only the executable"
fi

mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"

# Archive entries are sorted with fixed ownership and mtime for reproducibility.
tar --sort=name \
    --mtime=@0 \
    --owner=0 --group=0 --numeric-owner \
    --pax-option=delete=atime,delete=ctime \
    -C "$PACK" -czf "$OUT/$NAME" \
    skill-log LICENSE THIRD-PARTY-NOTICES.md NOTICE-LICENSES
(cd "$OUT" && sha256sum "$NAME" >"$NAME.sha256")
rm -rf "$PACK"

log "packaged:"
log "  $OUT/$NAME"
log "  $OUT/$NAME.sha256  $(cut -d' ' -f1 <"$OUT/$NAME.sha256")"
