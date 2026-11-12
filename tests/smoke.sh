#!/usr/bin/env bash
# The smoke test for the release-shaped artifact.
#
#   tests/smoke.sh
#
# It runs the built dist/ artifact in two environments:
#
#   1. plain — the artifact as staged, on this machine
#   2. sandbox — a bubblewrap root with no system SQLite anywhere, so the
#      SQLite that travels inside the binary is the only possible source
#
# The artifact is one statically linked executable: there is no lib/ beside
# it, no rpath, and no shared object to resolve. The sandbox is still the
# decisive environment: without it, a dynamically linked build would find
# the distro's SQLite and the failure path would never run.
#
# bwrap is used rather than a container: no daemon, no cgroup namespace,
# no privileges, and the desktop's live session cgroups are never touched.
# When bwrap is missing the sandbox checks are skipped, and the plain
# checks still run, so a developer without bwrap still gets signal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(dirname "$HERE")" && pwd)"
DIST="$ROOT/dist"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-smoke}"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_artifact() {
    if [ ! -x "$DIST/skill-log" ]; then
        printf 'smoke.sh: %s/skill-log is missing; run scripts/build.sh first\n' \
            "$DIST" >&2
        exit 1
    fi
    # The release ships one executable and nothing beside it: a lib/
    # directory in dist/ means the build picked up something it must not.
    if [ -d "$DIST/lib" ]; then
        printf 'smoke.sh: %s/lib must not be staged; the artifact is one static binary\n' \
            "$DIST" >&2
        exit 1
    fi
    # The reference area is never shipped: the archive stages only the
    # binary. A reference/ in dist/ means the build picked up something
    # it must not.
    if [ -e "$DIST/reference" ]; then
        printf 'smoke.sh: %s/reference must not be staged in the release archive\n' \
            "$DIST" >&2
        exit 1
    fi
}

# The number of example invocations in a rendered usage block: the lines
# under the `examples:` heading, not the usage lines above it.
count_examples() {
    sed -n '/^examples:$/,$p' "$1" | grep -c '^  ' || true
}

# static_binary <path>: the executable resolves no shared object at run
# time. ldd says so on a static ELF; where ldd is missing, file says it.
#
# ldd exits 1 when it prints "not a dynamic executable": that is the
# answer, not a failure, so the exit status is dropped and only the text
# is read.
static_binary() {
    local report
    if command -v ldd >/dev/null 2>&1; then
        report="$(ldd "$1" 2>&1 || true)"
        printf '%s\n' "$report" | grep -qi 'not a dynamic executable'
        return $?
    fi
    file "$1" 2>/dev/null | grep -qi 'statically linked'
}

require_artifact

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

# ------------------------------------------------------------ plain run
#
# The artifact as staged, run directly. These checks hold whether or not
# the machine has a system SQLite.

run_plain() {
    # run_plain <args...>: the artifact as staged, output in $SCRATCH/plain.*
    local out="$SCRATCH/plain"
    "$DIST/skill-log" "$@" >"$out.out" 2>"$out.err"
    echo $?
}

code="$(run_plain --version)"
check "plain: --version exits 0" "$code" "0"

version_line="$(cat "$SCRATCH/plain.out")"
if [ -n "$version_line" ]; then
    pass "plain: --version prints a version ($version_line)"
else
    fail "plain: --version prints a version"
fi

check "plain: --version prints nothing on stderr" \
    "$(wc -c < "$SCRATCH/plain.err" | tr -d ' ')" "0"

code="$(run_plain --help)"
check "plain: --help exits 0" "$code" "0"
check "plain: --help prints the usage on stdout" \
    "$(grep -c '^usage:' "$SCRATCH/plain.out")" "1"
check "plain: --help prints copy-pasteable examples" \
    "$(count_examples "$SCRATCH/plain.out")" "2"
check "plain: --help prints nothing on stderr" \
    "$(wc -c < "$SCRATCH/plain.err" | tr -d ' ')" "0"

code="$(run_plain -h)"
check "plain: -h exits 0" "$code" "0"

code="$(run_plain --version --help)"
check "plain: a verb's --help exits 0" "$code" "0"
check "plain: a verb's --help prints that verb's usage" \
    "$(grep -c '^usage:$' "$SCRATCH/plain.out")" "1"
check "plain: a verb's --help prints that verb's name" \
    "$(grep -c '^--version ' "$SCRATCH/plain.out")" "1"
check "plain: a verb's --help prints 2 to 4 real invocations" \
    "$(count_examples "$SCRATCH/plain.out")" "2"

code="$(run_plain)"
check "plain: no arguments exits 2" "$code" "2"
check "plain: no arguments keeps stdout empty" \
    "$(wc -c < "$SCRATCH/plain.out" | tr -d ' ')" "0"
check "plain: no arguments prints the usage" \
    "$(grep -c '^usage:' "$SCRATCH/plain.err")" "1"
check "plain: no arguments prints examples" \
    "$(count_examples "$SCRATCH/plain.err")" "2"

code="$(run_plain not-a-verb)"
check "plain: an unknown verb exits 2" "$code" "2"
check "plain: an unknown verb keeps stdout empty" \
    "$(wc -c < "$SCRATCH/plain.out" | tr -d ' ')" "0"
check "plain: an unknown verb prints exactly one stderr line" \
    "$(wc -l < "$SCRATCH/plain.err" | tr -d ' ')" "1"
check "plain: an unknown verb names the verb" \
    "$(grep -c '^skill-log: unknown verb: not-a-verb$' "$SCRATCH/plain.err")" "1"

# -------------------------------------------------------- static link proof
#
# The executable carries no shared object: the loader has nothing to
# resolve, so the SQLite inside it is the only SQLite there is.

if static_binary "$DIST/skill-log"; then
    pass "plain: the artifact is a static executable"
else
    fail "plain: the artifact is a static executable"
fi

# --------------------------------------------------------------- sandbox
#
# A root with no system libraries at all: no SQLite, no loader cache,
# no toolchain. The executable still runs, because the SQLite travels
# inside it.

sandbox_available=1
if ! command -v bwrap >/dev/null 2>&1 ||
    ! bwrap --ro-bind / / --dev /dev --unshare-all true >/dev/null 2>&1; then
    # A bwrap on the PATH that cannot create a namespace is not a
    # sandbox: the cases below would run in it and prove nothing.
    sandbox_available=0
fi

run_sandbox() {
    # run_sandbox <args...>: the command in the sandbox root.
    sandbox_run "$ROOTFS" "$SANDBOX_HOME" "$@"
}

if [ "$sandbox_available" -eq 0 ]; then
    printf 'skip bwrap is not installed: the sandbox checks did not run\n'
else
    ROOTFS="$SCRATCH/root"
    SANDBOX_HOME="$SCRATCH/sandbox-home"
    rm -rf "$SANDBOX_HOME"
    mkdir -p "$SANDBOX_HOME"
    sandbox_root "$ROOTFS" "$DIST/skill-log"

    # Positive: the executable runs with no system SQLite present.
    run_sandbox /pkg/skill-log --version \
        >"$SCRATCH/box.out" 2>"$SCRATCH/box.err"
    check "sandbox: --version exits 0 with no system SQLite" "$?" "0"
    check "sandbox: --version prints a version" \
        "$(grep -c '^[^[:space:]]' "$SCRATCH/box.out")" "1"

    run_sandbox /pkg/skill-log --help \
        >"$SCRATCH/boxhelp.out" 2>"$SCRATCH/boxhelp.err"
    check "sandbox: --help exits 0 with no system SQLite" "$?" "0"

    # The store works there too: the SQLite inside the binary writes a row
    # with no system SQLite anywhere on the machine.
    run_sandbox /pkg/skill-log add --skill sandboxed \
        >"$SCRATCH/boxadd.out" 2>"$SCRATCH/boxadd.err"
    check "sandbox: a write exits 0 with no system SQLite" "$?" "0"
    check "sandbox: a write prints the marker" \
        "$(grep -c '^[^[:space:]]' "$SCRATCH/boxadd.out")" "1"
    check "sandbox: a write prints nothing on stderr" \
        "$(wc -c < "$SCRATCH/boxadd.err" | tr -d ' ')" "0"

    # The root has no system libraries at all: no SQLite, no loader
    # cache, no toolchain. The runs above worked because the binary
    # carries its own.
    #
    # The root is read from the outside, where the truth is: the
    # diagnostics copied into it are dynamically linked and would not
    # run there anyway, which is the point.
    check "sandbox: the root carries no library directory" \
        "$([ -d "$ROOTFS/usr/lib" ] && printf yes || printf no)" "no"
    check "sandbox: the root carries no loader" \
        "$([ -e "$ROOTFS/lib64" ] && printf yes || printf no)" "no"
    check "sandbox: the root carries no SQLite library" \
        "$(find "$ROOTFS" -name 'libsqlite3*' 2>/dev/null | wc -l | tr -d ' ')" "0"
    check "sandbox: the root carries no toolchain" \
        "$(find "$ROOTFS/usr/bin" -maxdepth 1 \
            \( -name go -o -name mojo -o -name gcc -o -name cc \) 2>/dev/null |
            wc -l | tr -d ' ')" "0"
fi

# ------------------------------------------------------------------ done

tally
