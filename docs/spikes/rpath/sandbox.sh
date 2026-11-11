#!/usr/bin/env bash
# Build a minimal root filesystem that contains NO libsqlite3 at all, so the
# packaged binary's $ORIGIN/lib RUNPATH is the only possible source of
# SQLite.  Then run the spike inside it (bubblewrap), positive and negative.
#
#   ./sandbox.sh [scratch-dir]
#
# bwrap is used instead of a container: it needs no daemon, no cgroup
# namespace and no privileges, and the desktop's live session cgroups are
# never touched.
set -euo pipefail

SCRATCH="${1:-${SCRATCH:-/tmp/opencode/rpath-spike}}"
PKG="$SCRATCH/pkg"
ROOT="$SCRATCH/root"

command -v bwrap >/dev/null || { echo "bwrap not installed" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/usr/lib" "$ROOT/usr/lib32" "$ROOT/usr/bin" "$ROOT/lib64" "$ROOT/etc" "$ROOT/dev" "$ROOT/proc"
chmod 1777 "$ROOT"

# /usr/lib and /usr/lib32 without any libsqlite3*: the ld.so cache is not
# copied either, so the loader has nothing but its default search path.
python3 - "$ROOT" <<'PY'
import os, shutil, sys
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

# the dynamic loader must be a real file at /lib64
cp -a /lib64/ld-linux-x86-64.so.2 "$ROOT/lib64/"

# a few binaries for diagnostics inside the sandbox
for b in sh bash cat ls env; do
  p="$(command -v "$b" || true)"
  [ -n "$p" ] && cp -a "$p" "$ROOT/usr/bin/" || true
done

# the package under test
mkdir -p "$ROOT/pkg/lib"
cp -a "$PKG/skill-log-spike" "$PKG/skill-log-spike-uncaught" "$ROOT/pkg/"
cp -a "$PKG"/lib/*.so "$ROOT/pkg/lib/"
cp -a "$PKG"/lib/libsqlite3.so.0 "$ROOT/pkg/lib/"

run() {
  bwrap --ro-bind "$ROOT" / --bind /dev /dev --proc /proc --unshare-all \
        --die-with-parent --setenv HOME /tmp --setenv PATH /usr/bin:/bin \
        "$@"
}

echo "== POSITIVE: bundled libsqlite3.so.0 present, no system SQLite =="
run /pkg/skill-log-spike; echo "exit=$?"

echo
echo "== NEGATIVE: bundled libsqlite3.so.0 removed, no system SQLite =="
rm -f "$ROOT/pkg/lib/libsqlite3.so.0"
set +e
run /pkg/skill-log-spike >"$SCRATCH/neg.out" 2>"$SCRATCH/neg.err"
code=$?
set -e
echo "exit=$code"
echo "--- stdout ---"; cat "$SCRATCH/neg.out"
echo "--- stderr ---"; cat "$SCRATCH/neg.err"
echo "--- stderr lines: $(wc -l < "$SCRATCH/neg.err") ---"

echo
echo "== NEGATIVE, uncaught variant: Mojo's own diagnostic, not our line =="
set +e
run /pkg/skill-log-spike-uncaught >"$SCRATCH/neg2.out" 2>"$SCRATCH/neg2.err"
code=$?
set -e
echo "exit=$code"
echo "--- stdout ---"; cat "$SCRATCH/neg2.out"
echo "--- stderr ---"; cat "$SCRATCH/neg2.err"
echo "--- stderr lines: $(wc -l < "$SCRATCH/neg2.err") ---"
