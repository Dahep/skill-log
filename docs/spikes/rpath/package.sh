#!/usr/bin/env bash
# Package the spike exactly like the release layout of issue #3, then run
# the evidence suite.
#
#   ./package.sh [scratch-dir]
#
# The vendored binding (ffi.mojo + db.mojo) is copied from the read-only
# checkout of ehsanmok/sqlite v0.2.2 at $SQLITE_SRC unless it is already
# present next to this script (the committed spike copy wins).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="${1:-${SCRATCH:-/tmp/opencode/rpath-spike}}"
SQLITE_SRC="${SQLITE_SRC:-/tmp/opencode/sqlite-src}"

BUILD="$SCRATCH/build"
PKG="$SCRATCH/pkg"

MOJO_BIN="$(mise x -- which mojo)"
MOJO_LIB_DIR="$(dirname "$(readlink -f "$MOJO_BIN")")/../lib/python3.12/site-packages/modular/lib"

rm -rf "$BUILD" "$PKG"
mkdir -p "$BUILD/sqlite" "$PKG/lib"

# 1. the vendored binding: ffi.mojo + db.mojo only (no orm, no morph)
if [ -f "$HERE/sqlite/ffi.mojo" ]; then
  cp "$HERE/sqlite/ffi.mojo" "$HERE/sqlite/db.mojo" "$BUILD/sqlite/"
else
  cp "$SQLITE_SRC/sqlite/ffi.mojo" "$SQLITE_SRC/sqlite/db.mojo" "$BUILD/sqlite/"
fi
cat > "$BUILD/sqlite/__init__.mojo" <<'EOF'
"""Spike copy of the vendored SQLite binding: FFI + safe API only.

``orm.mojo`` is deliberately not taken (issue #3 excludes the ORM layer and
its ``morph`` dependency), so this trimmed ``__init__.mojo`` exposes only
``sqlite.db``.
"""

from .db import Database, Statement, Row, Transaction
EOF
cp "$HERE/main.mojo" "$BUILD/main.mojo"
cp "$HERE/main_uncaught.mojo" "$BUILD/main_uncaught.mojo"

# 2. build
mise x -- mojo build -I "$BUILD" -o "$BUILD/skill-log-spike" "$BUILD/main.mojo"
mise x -- mojo build -I "$BUILD" -o "$BUILD/skill-log-spike-uncaught" "$BUILD/main_uncaught.mojo"

# 3. package: binary at the archive root, libraries in lib/
cp "$BUILD/skill-log-spike" "$PKG/"
cp "$BUILD/skill-log-spike-uncaught" "$PKG/"
for so in libKGENCompilerRTShared.so libMSupportGlobals.so libAsyncRTRuntimeGlobals.so; do
  cp "$MOJO_LIB_DIR/$so" "$PKG/lib/"
done
# the real file behind the soname symlink, named with the soname the loader asks for
cp "$(readlink -f /usr/lib/libsqlite3.so.0)" "$PKG/lib/libsqlite3.so.0"

# 4. rpath
# shellcheck disable=SC2016  # $ORIGIN must reach patchelf literally
patchelf --set-rpath '$ORIGIN/lib' "$PKG/skill-log-spike"
# shellcheck disable=SC2016
patchelf --set-rpath '$ORIGIN/lib' "$PKG/skill-log-spike-uncaught"

echo "== readelf -d =="
readelf -d "$PKG/skill-log-spike" | grep -iE 'NEEDED|RUNPATH|RPATH'
echo "== ldd =="
ldd "$PKG/skill-log-spike"
