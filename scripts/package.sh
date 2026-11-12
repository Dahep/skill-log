#!/usr/bin/env bash
# Build the release archive: the versioned artifact mise installs.
#
#   scripts/package.sh --version vX.Y.Z
#   scripts/package.sh --version vX.Y.Z --sqlite /path/to/libsqlite3.so.0
#
# Produces, in dist/ (or --out):
#
#   skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz
#   skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz.sha256
#
# The archive holds exactly `skill-log` and `lib/` (the three Mojo
# runtime libraries and libsqlite3.so.0), never reference/ or tests/.
#
# The bundled SQLite is never taken from this machine. By default it is
# fetched from the pinned Ubuntu 22.04 (jammy) libsqlite3-0 package — a
# glibc 2.35 floor — verified against the sha256 Ubuntu's signed archive
# index records for it, then verified again as the extracted file.
# `--sqlite <path>` substitutes a locally built copy, checked the same
# way: an ELF shared object with the libsqlite3.so.0 soname and the same
# glibc floor. Nothing falls back to a development machine's library;
# the release job fails if the library is missing or too new.
#
# The version is baked in from --version, else SKILL_LOG_VERSION, else
# `git describe --tags`; a release always passes the tag (vX.Y.Z), which
# is also the archive name's version and what `--version` prints.
#
# The download is cached in .package-cache/ and re-verified on every run,
# so a re-run needs no network once the cache is warm.
#
# This rebuilds dist/ from scratch (scripts/build.sh clears it), so the
# gate order is: build.sh, test.sh (or just test.sh --build), then
# package.sh, then tests/packaging.sh — the packaging test runs against
# the archive package.sh just produced.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The pinned Ubuntu 22.04 (jammy) libsqlite3-0, the newest
# jammy-updates/jammy-security build. The deb's sha256 is the one in
# Ubuntu's signed archive index
# (dists/jammy-updates/main/binary-amd64/Packages.gz, "SHA256:"); the
# Launchpad librarian URL keeps superseded files available forever, so
# the pin cannot rot when the pool moves on. The extracted file's
# sha256 is pinned as well: that is the file the release ships.
SQLITE_DEB=libsqlite3-0_3.37.2-2ubuntu0.8_amd64.deb
SQLITE_DEB_URL="https://launchpad.net/ubuntu/+archive/primary/+files/$SQLITE_DEB"
SQLITE_DEB_SHA256=6e22b1e8d375fed6a1d52cad5887e762b6cdeaba137595e726c95486968dfab5
SQLITE_DEB_SO=usr/lib/x86_64-linux-gnu/libsqlite3.so.0.8.6
SQLITE_SO_SHA256=f5a7fc236f80f3185608d14e9f4dea3e3fd647582e123e8a00f253629fe16830

# The glibc floor the bundled SQLite may require at most: the jammy
# package's own floor. A library needing more than this would silently
# raise the release's floor, so it is refused.
GLIBC_FLOOR="${SKILL_LOG_SQLITE_FLOOR:-2.35}"

# The archive shape of SPEC.md §8.
TARGET=x86_64-unknown-linux-gnu

CACHE="$ROOT/.package-cache"

log() { printf '==> %s\n' "$*"; }

die() {
    printf 'package.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
usage: scripts/package.sh [--version <vX.Y.Z>] [--sqlite <path>] [--out <dir>]

  --version <vX.Y.Z>  the release version (default: SKILL_LOG_VERSION,
                      then git describe --tags)
  --sqlite <path>     bundle this libsqlite3.so.0 instead of fetching
                      the pinned Ubuntu 22.04 package
  --out <dir>         where the archive goes (default: dist/)
EOF
}

VERSION_ARG=""
SQLITE_ARG=""
OUT="$ROOT/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version needs a value"
            VERSION_ARG="$2"
            shift 2
            ;;
        --sqlite)
            [ $# -ge 2 ] || die "--sqlite needs a path"
            SQLITE_ARG="$2"
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

for tool in readelf sha256sum tar curl; do
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
    */* | *' '* | *$'\t'*) die "version must not contain a slash or space: $VERSION" ;;
esac

# ----------------------------------------------------------------- sqlite

# check_sqlite <file> <label>: the shape every bundled library must have.
check_sqlite() {
    local file="$1" label="$2" soname max floor
    [ -f "$file" ] || die "$label is not a file: $file"
    readelf -h "$file" 2>/dev/null | grep -q 'Type:.*DYN' ||
        die "$label is not an ELF shared object: $file"
    soname="$(readelf -d "$file" 2>/dev/null |
        sed -n 's/.*(SONAME).*\[\(.*\)\]$/\1/p')"
    [ "$soname" = "libsqlite3.so.0" ] ||
        die "$label has soname '$soname', expected libsqlite3.so.0"

    # The glibc floor guard: the library's own symbol needs must not
    # exceed the floor. This is what refuses a development machine's
    # SQLite on a modern distro.
    max="$(readelf --version-info "$file" 2>/dev/null |
        grep -o 'GLIBC_[0-9.]*' | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)"
    if [ -n "$max" ]; then
        floor="$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$max" | sort -uV | tail -1)"
        [ "$floor" = "$GLIBC_FLOOR" ] ||
            die "$label needs GLIBC_$max, above the $GLIBC_FLOOR floor: $file"
    fi
}

# The pinned fetch: download once into the cache, verify both hashes on
# every run, and use the extracted file. Its stdout is only the path —
# the caller captures it — so every message goes to stderr.
fetch_sqlite() {
    local deb="$CACHE/$SQLITE_DEB" so

    if [ ! -f "$deb" ]; then
        log "fetching $SQLITE_DEB" >&2
        mkdir -p "$CACHE"
        curl -fsSL --retry 3 -o "$deb.part" "$SQLITE_DEB_URL" ||
            die "cannot download $SQLITE_DEB_URL"
        mv "$deb.part" "$deb"
    fi

    printf '%s  %s\n' "$SQLITE_DEB_SHA256" "$deb" | sha256sum -c - >/dev/null ||
        die "the downloaded $SQLITE_DEB does not match its pinned sha256"

    so="$CACHE/libsqlite3.so.0"
    if [ ! -f "$so" ] ||
        ! printf '%s  %s\n' "$SQLITE_SO_SHA256" "$so" | sha256sum -c - >/dev/null; then
        log "extracting $SQLITE_DEB" >&2
        rm -rf "$CACHE/extract"
        mkdir -p "$CACHE/extract"
        if command -v dpkg-deb >/dev/null 2>&1; then
            dpkg-deb -x "$deb" "$CACHE/extract" ||
                die "cannot extract $SQLITE_DEB"
        else
            command -v zstd >/dev/null 2>&1 ||
                die "zstd is required to extract $SQLITE_DEB"
            (cd "$CACHE/extract" && ar x "$deb") ||
                die "cannot extract $SQLITE_DEB"
            tar --zstd -xf "$CACHE/extract/data.tar.zst" -C "$CACHE/extract" ||
                die "cannot unpack $SQLITE_DEB"
        fi
        [ -f "$CACHE/extract/$SQLITE_DEB_SO" ] ||
            die "$SQLITE_DEB does not contain $SQLITE_DEB_SO"
        cp "$CACHE/extract/$SQLITE_DEB_SO" "$so"
    fi

    printf '%s  %s\n' "$SQLITE_SO_SHA256" "$so" | sha256sum -c - >/dev/null ||
        die "the extracted libsqlite3.so.0 does not match its pinned sha256"

    printf '%s' "$so"
}

if [ -n "$SQLITE_ARG" ]; then
    SQLITE="$(readlink -f "$SQLITE_ARG" 2>/dev/null || true)"
    [ -n "$SQLITE" ] || die "--sqlite path does not exist: $SQLITE_ARG"
    log "sqlite: $SQLITE (given)"
else
    SQLITE="$(fetch_sqlite)"
    log "sqlite: $SQLITE (pinned $SQLITE_DEB)"
fi
check_sqlite "$SQLITE" "the bundled SQLite"

# ------------------------------------------------------------------ build

SKILL_LOG_VERSION="$VERSION" SKILL_LOG_SQLITE="$SQLITE" "$HERE/build.sh"

# ------------------------------------------------------------ pack + hash

STAGE="$ROOT/dist"
NAME="skill-log-$VERSION-$TARGET.tar.gz"

[ -x "$STAGE/skill-log" ] || die "$STAGE/skill-log is missing after the build"

staged="$(ls "$STAGE/lib" | sort)"
expected="$(printf '%s\n' \
    libAsyncRTRuntimeGlobals.so \
    libKGENCompilerRTShared.so \
    libMSupportGlobals.so \
    libsqlite3.so.0 | sort)"
[ "$staged" = "$expected" ] ||
    die "$STAGE/lib holds more (or less) than the four libraries"

mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/$NAME" skill-log lib
(cd "$OUT" && sha256sum "$NAME" >"$NAME.sha256")

log "packaged:"
log "  $OUT/$NAME"
log "  $OUT/$NAME.sha256  $(cut -d' ' -f1 <"$OUT/$NAME.sha256")"