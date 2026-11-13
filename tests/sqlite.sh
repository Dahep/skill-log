#!/usr/bin/env bash
# The pinned-SQLite test: the artifact against the SQLite it ships.
#
#   tests/sqlite.sh
#
# The release bundles a pinned SQLite — the jammy package
# `libsqlite3-0_3.37.2-2ubuntu0.8_amd64.deb` — and the default gate
# builds against the machine's own copy, which is newer. So the gate can
# be green while the released artifact cannot write a row: the clock
# query the writer uses has to work on the library that ships.
#
# This suite builds the artifact against the pinned library when it is
# available (scripts/package.sh fetches and verifies it), and runs the
# store's write path against it. Without the pinned library the case
# prints a skip rather than pretending it ran.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-sqlite-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a
# caller's SCRATCH is theirs to clean up. A fixed path would let two
# runs on one machine clobber each other's stores.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck shell=bash
# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

# The pinned library: the one scripts/package.sh fetches and verifies.
PINNED=""
for candidate in \
    "$ROOT/.package-cache/libsqlite3.so.0" \
    "$ROOT/.package-cache/extract/usr/lib/x86_64-linux-gnu/libsqlite3.so.0"; do
    if [ -f "$candidate" ]; then
        PINNED="$candidate"
        break
    fi
done

if [ -z "$PINNED" ]; then
    printf 'skip: the pinned libsqlite3.so.0 is not here; run scripts/package.sh first\n'
    exit 0
fi

printf 'pinned library: %s\n' "$PINNED"

# The tools the case needs: the pinned toolchain, the patcher that
# points the artifact at its own libraries, and the SQLite CLI that
# inspects what the artifact wrote. A suite that cannot run must say so
# and stop, rather than compare the empty output of a missing command
# against empty.
require_tools mise patchelf sqlite3

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" "$SCRATCH/build" "$SCRATCH/src"

# The artifact, built against the pinned library: the same sources, the
# same build script, the library the release ships.
#
# The copy creates the directory it lands in, and the version file it
# brings is replaced by the heredoc below — the build writes its own
# version there, and a build that read the checkout's placeholder would
# not be the release-shaped build.
cp -r "$ROOT/src/skill_log/." "$SCRATCH/src/skill_log/"
cat >"$SCRATCH/src/skill_log/version.mojo" <<'EOF'
"""The release version, baked in at build time."""


def version() -> String:
    """The release version of this build."""
    return "0.0.0-test"
EOF

MOJO_BIN="$(mise x -- which mojo)"
if ! "$MOJO_BIN" build -I "$ROOT/vendor" -I "$SCRATCH/src" \
    -o "$SCRATCH/build/skill-log" "$SCRATCH/src/skill_log/main.mojo" \
    >"$SCRATCH/build.log" 2>&1; then
    fail "the artifact builds against the pinned library"
    printf '     %s\n' "$(tail -5 "$SCRATCH/build.log")"
    tally
    exit 1
fi
pass "the artifact builds against the pinned library"

# The bundled libraries, beside the binary: the release's own layout. The
# Mojo runtime libraries come from the artifact `scripts/build.sh`
# staged; only the SQLite is the one under test.
mkdir -p "$SCRATCH/build/lib"
for lib in "$ROOT"/dist/lib/*.so*; do
    [ -e "$lib" ] || continue
    cp "$lib" "$SCRATCH/build/lib/"
done
cp "$PINNED" "$SCRATCH/build/lib/libsqlite3.so.0"
# shellcheck disable=SC2016  # $ORIGIN must reach patchelf literally
patchelf --set-rpath '$ORIGIN/lib' "$SCRATCH/build/skill-log"
BIN="$SCRATCH/build/skill-log"

run() {
    OUT="$(env -u XDG_STATE_HOME -u SKILL_LOG_DB HOME="$SCRATCH/home" \
        "$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
    export ERR
}

# The write path: the row, its timestamp, and its marker. The clock is
# read through SQLite, so this is the case that says whether the pinned
# library can carry the tool.
run add --skill alpha
check "a write against the pinned library exits 0" "$STATUS" "0"
check "a write against the pinned library prints the marker" \
    "$OUT" "$(hostname)#1"
check "the row carries a local ISO 8601 stamp with an offset" \
    "$(sqlite3 "$SCRATCH/home/.local/state/skill-log/skills.db" \
        "select ts from invocations" \
        | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"

# The read path, and the resolution that writes a stamp — both go through
# the same clock.
run show --json
check "a read against the pinned library exits 0" "$STATUS" "0"
check "a read against the pinned library reads the row" \
    "$(json_field "$OUT" skill)" "alpha"

run resolve --id 1 --fix abc1234
check "a resolve against the pinned library exits 0" "$STATUS" "0"
check "the resolved row carries a timestamp" \
    "$(sqlite3 "$SCRATCH/home/.local/state/skill-log/skills.db" \
        "select count(*) from invocations where resolved_at <> ''")" "1"

tally
