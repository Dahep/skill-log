#!/usr/bin/env bash
# The smoke test for the release-shaped artifact.
#
#   tests/smoke.sh
#
# It runs the built dist/ artifact in two environments:
#
#   1. plain — the artifact as staged, on this machine
#   2. sandbox — a bubblewrap root with no system SQLite anywhere, so the
#      bundled copy in dist/lib/ is the only possible source
#
# The sandbox is the decisive one: without it, removing the bundled
# libsqlite3.so.0 would fall through to the loader cache and find the
# distro copy, and the failure path would never run.
#
# bwrap is used rather than a container: no daemon, no cgroup namespace,
# no privileges, and the desktop's live session cgroups are never touched.
# When bwrap is missing the sandbox checks are skipped, and the plain
# checks still run, so a developer without bwrap still gets signal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-smoke}"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$1"
}

check() {
    # check <name> <condition-description> <actual> <expected>
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

require_artifact() {
    if [ ! -x "$DIST/skill-log" ]; then
        printf 'smoke.sh: %s/skill-log is missing; run scripts/build.sh first\n' \
            "$DIST" >&2
        exit 1
    fi
    if [ ! -f "$DIST/lib/libsqlite3.so.0" ]; then
        printf 'smoke.sh: %s/lib/libsqlite3.so.0 is missing; run scripts/build.sh first\n' \
            "$DIST" >&2
        exit 1
    fi
    # The reference area is never shipped: the archive stages only the
    # binary and its libraries. A reference/ in dist/ means the build
    # picked up something it must not.
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

require_artifact

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

# ------------------------------------------------------------ plain run
#
# The artifact as staged, run directly. These checks hold whether or not
# the machine has a system SQLite.

run_plain() {
    local out="$SCRATCH/plain"
    shift
    "$DIST/skill-log" "$@" >"$out.out" 2>"$out.err"
    echo $?
}

code="$(run_plain plain --version)"
check "plain: --version exits 0" "$code" "0"

version_line="$(cat "$SCRATCH/plain.out")"
if [ -n "$version_line" ]; then
    pass "plain: --version prints a version ($version_line)"
else
    fail "plain: --version prints a version"
fi

check "plain: --version prints nothing on stderr" \
    "$(wc -c < "$SCRATCH/plain.err" | tr -d ' ')" "0"

code="$(run_plain plain --help)"
check "plain: --help exits 0" "$code" "0"
check "plain: --help prints the usage on stdout" \
    "$(grep -c '^usage:' "$SCRATCH/plain.out")" "1"
check "plain: --help prints copy-pasteable examples" \
    "$(count_examples "$SCRATCH/plain.out")" "2"
check "plain: --help prints nothing on stderr" \
    "$(wc -c < "$SCRATCH/plain.err" | tr -d ' ')" "0"

code="$(run_plain plain -h)"
check "plain: -h exits 0" "$code" "0"

code="$(run_plain plain --version --help)"
check "plain: a verb's --help exits 0" "$code" "0"
check "plain: a verb's --help prints that verb's usage" \
    "$(grep -c '^usage:$' "$SCRATCH/plain.out")" "1"
check "plain: a verb's --help prints that verb's name" \
    "$(grep -c '^--version ' "$SCRATCH/plain.out")" "1"
check "plain: a verb's --help prints 2 to 4 real invocations" \
    "$(count_examples "$SCRATCH/plain.out")" "2"

code="$(run_plain plain)"
check "plain: no arguments exits 2" "$code" "2"
check "plain: no arguments keeps stdout empty" \
    "$(wc -c < "$SCRATCH/plain.out" | tr -d ' ')" "0"
check "plain: no arguments prints the usage" \
    "$(grep -c '^usage:' "$SCRATCH/plain.err")" "1"
check "plain: no arguments prints examples" \
    "$(count_examples "$SCRATCH/plain.err")" "2"

code="$(run_plain plain not-a-verb)"
check "plain: an unknown verb exits 2" "$code" "2"
check "plain: an unknown verb keeps stdout empty" \
    "$(wc -c < "$SCRATCH/plain.out" | tr -d ' ')" "0"
check "plain: an unknown verb prints exactly one stderr line" \
    "$(wc -l < "$SCRATCH/plain.err" | tr -d ' ')" "1"
check "plain: an unknown verb names the verb" \
    "$(grep -c '^skill-log: unknown verb: not-a-verb$' "$SCRATCH/plain.err")" "1"

# ---------------------------------------------------------- LD_DEBUG proof
#
# The bundled libsqlite3.so.0 is the one that gets loaded: the loader
# search trace names the path inside dist/lib/.

LD_DEBUG=libs "$DIST/skill-log" --version >"$SCRATCH/ld.out" 2>"$SCRATCH/ld.err"
check "plain: the loader resolves libsqlite3.so.0 from dist/lib" \
    "$(grep -c "calling init: $DIST/lib/libsqlite3.so.0" "$SCRATCH/ld.err")" "1"

# --------------------------------------------------------------- sandbox
#
# A root with no system SQLite at all: the packaged copy is the only
# possible source, and removing it must produce one named line.

sandbox_available=1
command -v bwrap >/dev/null 2>&1 || sandbox_available=0

build_sandbox_root() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/usr/lib" "$root/usr/lib32" "$root/usr/bin" "$root/lib64" \
        "$root/etc" "$root/dev" "$root/proc" "$root/pkg/lib"
    chmod 1777 "$root"

    # /usr/lib and /usr/lib32 without any libsqlite3*, and without the
    # ld.so cache, so the loader has nothing but its default search path.
    python3 - "$root" <<'PY'
import os
import shutil
import sys

root = sys.argv[1]
for src, dst in (("/usr/lib", os.path.join(root, "usr/lib")),
                 ("/usr/lib32", os.path.join(root, "usr/lib32"))):
    if not os.path.isdir(src):
        continue
    for name in sorted(os.listdir(src)):
        if "sqlite" in name:
            continue
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        try:
            if os.path.islink(s):
                if os.path.lexists(d):
                    os.remove(d)
                tgt = os.readlink(s)
                full = os.path.join(src, tgt)
                if os.path.isfile(full):
                    shutil.copy2(full, d)
                else:
                    os.symlink(tgt, d)
            elif os.path.isdir(s):
                os.makedirs(d, exist_ok=True)
            elif not os.path.lexists(d):
                try:
                    os.link(s, d)
                except OSError:
                    try:
                        shutil.copy2(s, d)
                    except OSError:
                        pass
        except OSError:
            pass
PY

    # The dynamic loader must be a real file at /lib64.
    cp -a /lib64/ld-linux-x86-64.so.2 "$root/lib64/"

    # A few binaries for diagnostics inside the sandbox.
    for b in sh bash cat ls env; do
        p="$(command -v "$b" || true)"
        [ -n "$p" ] && cp -a "$p" "$root/usr/bin/" || true
    done

    # The package under test.
    cp -a "$DIST/skill-log" "$root/pkg/"
    cp -a "$DIST"/lib/*.so "$root/pkg/lib/" 2>/dev/null || true
    cp -a "$DIST/lib/libsqlite3.so.0" "$root/pkg/lib/"
}

run_sandbox() {
    # run_sandbox <root> <args...>
    local root="$1"
    shift
    bwrap --ro-bind "$root" / --bind /dev /dev --proc /proc --unshare-all \
        --die-with-parent --setenv HOME /tmp --setenv PATH /usr/bin:/bin \
        "$@"
}

if [ "$sandbox_available" -eq 0 ]; then
    printf 'skip bwrap is not installed: the sandbox checks did not run\n'
else
    ROOTFS="$SCRATCH/root"
    build_sandbox_root "$ROOTFS"

    # Positive: the bundled copy is found with no system SQLite present.
    run_sandbox "$ROOTFS" /pkg/skill-log --version \
        >"$SCRATCH/box.out" 2>"$SCRATCH/box.err"
    check "sandbox: --version exits 0 with no system SQLite" "$?" "0"
    check "sandbox: --version prints a version" \
        "$(grep -c '^[^[:space:]]' "$SCRATCH/box.out")" "1"

    run_sandbox "$ROOTFS" /pkg/skill-log --help \
        >"$SCRATCH/boxhelp.out" 2>"$SCRATCH/boxhelp.err"
    check "sandbox: --help exits 0 with no system SQLite" "$?" "0"

    # The loader proof, inside the sandbox: the packaged copy is loaded.
    LD_DEBUG=libs run_sandbox "$ROOTFS" /pkg/skill-log --version \
        >"$SCRATCH/boxld.out" 2>"$SCRATCH/boxld.err"
    check "sandbox: the loader resolves libsqlite3.so.0 from the package" \
        "$(grep -c 'calling init: /pkg/lib/libsqlite3.so.0' "$SCRATCH/boxld.err")" "1"

    # Negative: the bundled copy removed, and there is no system SQLite to
    # fall back on. One named line, exit 1, no traceback.
    rm -f "$ROOTFS/pkg/lib/libsqlite3.so.0"
    run_sandbox "$ROOTFS" /pkg/skill-log --version \
        >"$SCRATCH/neg.out" 2>"$SCRATCH/neg.err"
    neg_code=$?
    check "sandbox: a missing bundled SQLite exits 1" "$neg_code" "1"
    check "sandbox: a missing bundled SQLite keeps stdout empty" \
        "$(wc -c < "$SCRATCH/neg.out" | tr -d ' ')" "0"
    check "sandbox: a missing bundled SQLite prints exactly one stderr line" \
        "$(wc -l < "$SCRATCH/neg.err" | tr -d ' ')" "1"
    check "sandbox: a missing bundled SQLite names the cause" \
        "$(grep -c '^skill-log: sqlite unavailable: ' "$SCRATCH/neg.err")" "1"
    check "sandbox: a missing bundled SQLite prints no traceback" \
        "$(grep -ci 'unhandled exception\|stack trace' "$SCRATCH/neg.err")" "0"

    printf 'negative-test stderr: %s\n' "$(cat "$SCRATCH/neg.err")"
fi

# ------------------------------------------------------------------ done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
