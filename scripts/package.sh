#!/usr/bin/env bash
# Build the release archive: the versioned artifact mise installs.
#
#   scripts/package.sh --version vX.Y.Z
#   scripts/package.sh --version vX.Y.Z --out /tmp/release
#
# Produces, in dist/ (or --out):
#
#   skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz
#   skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz.sha256
#
# The archive holds one statically linked executable plus the licence
# material a redistributor must carry:
#
#   skill-log              the executable (CGO_ENABLED=0, no shared object)
#   LICENSE                this project's licence (MIT)
#   THIRD-PARTY-NOTICES.md the notices of everything linked into the binary
#   NOTICE-LICENSES/       the licence texts those notices point at
#
# Nothing else is shipped: no reference/, no tests/, no lib/ and no
# shared object at all. The SQLite implementation is pure Go and travels
# inside the executable, so there is no library to fetch, to bundle or to
# resolve at run time — and no .package-cache to keep warm.
#
# The version is baked in from --version, else SKILL_LOG_VERSION, else
# `git describe --tags`; a release always passes the tag (vX.Y.Z), which
# is also the archive name's version and what `--version` prints.
#
# The notices are read from the module cache, resolved through `go list -m`,
# so they always match the version of modernc.org/sqlite that go.mod pins:
# no checked-in copy can drift away from what the binary actually links.
#
# This rebuilds dist/ from scratch (scripts/build.sh clears it), so the
# gate order is: build.sh, test.sh (or just test.sh --build), then
# package.sh, then tests/packaging.sh — the packaging test runs against
# the archive package.sh just produced.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(dirname "$HERE")" && pwd)"

# The archive shape of SPEC.md §8.
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
# The archive name states the target: x86_64-unknown-linux-gnu. The
# binary must be that target, or the name lies about what is inside the
# archive.
#
# Two things guard that. The build is given the target explicitly, so
# the binary is amd64-linux whatever the builder's own machine is. And
# the toolchain's target is checked first: a builder whose go env says
# otherwise is a misconfigured builder, and the archive refuses to be
# produced by it rather than quietly cross-building from a host the
# release was never tested on.

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
# The binary links modernc.org/sqlite, whose module carries the flattened
# third-party notices and the licence texts they point at. The module
# directory is resolved through `go list -m`, so the notices are always the
# ones of the version go.mod pins.

MODULE_DIR="$(go list -m -f '{{.Dir}}' modernc.org/sqlite 2>/dev/null || true)"
[ -n "$MODULE_DIR" ] && [ -d "$MODULE_DIR" ] ||
    die "the modernc.org/sqlite module is not in the module cache; run go mod download"

NOTICE="$MODULE_DIR/LICENSE-3RD-PARTY.md"
[ -f "$NOTICE" ] ||
    die "$NOTICE is missing; the module carries no third-party notices"

# The licence texts the notices reference, by the names the notices use.
# Every file the notices point at is shipped, so a reader of the archive
# never meets a reference that does not resolve.
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

# The driver's licence files keep their names inside NOTICE-LICENSES/, so
# the archive root's LICENSE stays this project's own. The notices file
# points at the driver's licences by their upstream names; those names are
# repointed at the copies' real place, and the rewrite is asserted so a
# change upstream cannot slip an unfixed reference into the archive.
#
# The backticks in the patterns are the notices file's own quoting, not
# shell substitution: they must reach sed literally.
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

# Every file the notices point at is in the archive: a reference that does
# not resolve is a licence nobody can read.
#
# The grep may match nothing, and a pipeline whose first command fails
# kills the script under `set -o pipefail` — before the `die`s below
# could report anything. The `|| true` keeps the empty result an empty
# file, so a notices file with no reference is a fact the loop reads,
# not a silent death.
grep -oE 'NOTICE-LICENSES/[A-Za-z0-9._-]+' "$PACK/THIRD-PARTY-NOTICES.md" |
    sort -u >"$PACK/.referenced" || true
while IFS= read -r referenced; do
    [ -n "$referenced" ] || continue
    [ -f "$PACK/$referenced" ] ||
        die "the third-party notices point at $referenced, which the archive does not carry"
done <"$PACK/.referenced"
rm -f "$PACK/.referenced"

# The three licence files this archive ships are named in the notices by
# their upstream names; the rewrite above must have caught every one of
# them, or a licence the notices point at is not in the archive. The other
# names in the notices are paths inside the upstream module tree, whose
# texts the notices reproduce in full in their own appendix.
for name in "${NOTICE_LICENSES[@]}"; do
    grep -qF "NOTICE-LICENSES/$name" "$PACK/THIRD-PARTY-NOTICES.md" ||
        die "the third-party notices no longer name $name"
done

# The archive carries no shared object: the executable is statically
# linked, so there is nothing to resolve at run time.
if find "$PACK" -type f -name '*.so*' | grep -q .; then
    die "the staged tree holds a shared object; the archive must carry only the executable"
fi

mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"

# The archive is byte-reproducible: the entries are sorted, the owner is
# fixed, and the mtime is a constant. A release digest that changes when
# nothing changed is a digest nobody can verify twice.
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
