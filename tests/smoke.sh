#!/usr/bin/env bash
# Smoke suite: verifies the release artifact directly and in a sandbox.
# Run: tests/smoke.sh
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
    if [ -d "$DIST/lib" ]; then
        printf 'smoke.sh: %s/lib must not be staged; the artifact is one static binary\n' \
            "$DIST" >&2
        exit 1
    fi
}

count_examples() {
    sed -n '/^examples:$/,$p' "$1" | grep -c '^  ' || true
}

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

if static_binary "$DIST/skill-log"; then
    pass "plain: the artifact is a static executable"
else
    fail "plain: the artifact is a static executable"
fi

# --------------------------------------------------------------- sandbox

sandbox_available=1
if ! command -v bwrap >/dev/null 2>&1 ||
    ! bwrap --ro-bind / / --dev /dev --unshare-all true >/dev/null 2>&1; then
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
