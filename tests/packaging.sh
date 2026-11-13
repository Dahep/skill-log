#!/usr/bin/env bash
# The packaging test: the release archive installed into a clean
# container.
#
#   tests/packaging.sh
#   tests/packaging.sh --archive dist/skill-log-v1.0.0-x86_64-unknown-linux-gnu.tar.gz
#   tests/packaging.sh --image ubuntu:22.04
#
# The archive is unpacked into a container that has no toolchain and no
# system SQLite. There `--version` and `setup --dry-run` run against a
# scratch repo, the loader trace shows the archive's own
# lib/libsqlite3.so.0 being the one loaded, and removing that file makes
# the binary fail with one named line — so the bundled copy is proven to
# be the only source, not merely present.
#
# The default image is debian:bookworm-slim: no toolchain, no system
# SQLite, glibc 2.36 above the artifact's 2.35 floor. Override the image
# with --image or SKILL_LOG_PACKAGING_IMAGE.
#
# The image carries no git, so `setup --dry-run`'s repo-scoped artifacts
# are asserted through the named skip.
#
# This is not part of scripts/test.sh: it needs docker, so the default
# gate stays offline and fast.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SCRATCH_GIVEN="${SCRATCH:-}"
SCRATCH="${SCRATCH:-$(mktemp -d /tmp/opencode/skill-log-packaging-XXXXXX)}"
# The suite owns a scratch directory only when it made one: a caller's
# SCRATCH is theirs to clean up.
if [ -z "$SCRATCH_GIVEN" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

IMAGE="${SKILL_LOG_PACKAGING_IMAGE:-debian:bookworm-slim}"
ARCHIVE=""

usage() {
    cat <<EOF
usage: tests/packaging.sh [--archive <tar.gz>] [--image <image>]

  --archive <tar.gz>  the archive under test (default: the only
                      skill-log-*-x86_64-unknown-linux-gnu.tar.gz in dist/)
  --image <image>     the clean container (default: debian:bookworm-slim)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --archive)
            [ $# -ge 2 ] || {
                printf 'packaging.sh: --archive needs a path\n' >&2
                exit 2
            }
            ARCHIVE="$2"
            shift 2
            ;;
        --image)
            [ $# -ge 2 ] || {
                printf 'packaging.sh: --image needs an image\n' >&2
                exit 2
            }
            IMAGE="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'packaging.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_tools docker tar sha256sum

# ------------------------------------------------------------ the archive

if [ -z "$ARCHIVE" ]; then
    # The archive scripts/package.sh produces; the name is the release
    # contract of SPEC.md §8.
    candidates=("$ROOT"/dist/skill-log-*-x86_64-unknown-linux-gnu.tar.gz)
    if [ ! -f "${candidates[0]}" ]; then
        printf 'packaging.sh: no dist/skill-log-*-x86_64-unknown-linux-gnu.tar.gz; run scripts/package.sh first\n' >&2
        exit 1
    fi
    if [ "${#candidates[@]}" -ne 1 ]; then
        printf 'packaging.sh: more than one archive in dist/; pass --archive\n' >&2
        exit 1
    fi
    ARCHIVE="${candidates[0]}"
fi

[ -f "$ARCHIVE" ] || {
    printf 'packaging.sh: %s is not a file\n' "$ARCHIVE" >&2
    exit 1
}

base="$(basename "$ARCHIVE")"
version="${base#skill-log-}"
version="${version%-x86_64-unknown-linux-gnu.tar.gz}"

# ------------------------------------------------------- the packed shape
#
# Exactly the executable and its four libraries. Nothing from the tree
# the build read is shipped, and the listing check proves it.

listing="$(tar -tzf "$ARCHIVE" | sort)"
expected="$(printf '%s\n' \
    skill-log \
    'lib/' \
    'lib/libAsyncRTRuntimeGlobals.so' \
    'lib/libKGENCompilerRTShared.so' \
    'lib/libMSupportGlobals.so' \
    'lib/libsqlite3.so.0' | sort)"

check "archive: entries are exactly the binary and its four libraries" \
    "$listing" "$expected"
check_absent "archive: no tests/ is shipped" "$listing" "tests/"
check_absent "archive: no src/ is shipped" "$listing" "src/"
check_absent "archive: no vendor/ is shipped" "$listing" "vendor/"
check_absent "archive: no docs/ is shipped" "$listing" "docs/"

# The digest the release uploads beside the archive. It is part of the
# artifact pair, so its absence is a failure, not a skip.
DIGEST="$ARCHIVE.sha256"
if [ ! -f "$DIGEST" ]; then
    fail "archive: $DIGEST is missing (run scripts/package.sh)"
else
    if (cd "$(dirname "$ARCHIVE")" &&
        sha256sum -c "$(basename "$DIGEST")" >/dev/null 2>&1); then
        pass "archive: the sha256 file names the archive and matches"
    else
        fail "archive: the sha256 file does not verify"
    fi
fi

# ------------------------------------------------------- the container run

command -v docker >/dev/null 2>&1 || {
    printf 'packaging.sh: docker is required\n' >&2
    exit 1
}

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

INNER="$SCRATCH/inner.sh"

cat >"$INNER" <<'INNER'
#!/usr/bin/env bash
# The in-container half of the packaging test. Sourced harness, plain
# environment.
set -uo pipefail

# shellcheck disable=SC1091
. /in/lib.sh

PKG=/tmp/pkg
NEG=/tmp/neg
SCRATCH=/tmp/pkg-test
REPO=/tmp/scratch-repo

# ------------------------------------------------- the image is clean

check "image: no Mojo toolchain" \
    "$(command -v mojo 2>/dev/null || true)" ""
check "image: no system SQLite under /usr/lib" \
    "$(find /usr/lib -name 'libsqlite3.so*' 2>/dev/null | wc -l | tr -d ' ')" "0"
check "image: no system SQLite under /lib" \
    "$(find /lib /lib64 -name 'libsqlite3.so*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# ------------------------------------------------------------- install

mkdir -p "$PKG" "$SCRATCH"
tar -xzf /in/archive.tar.gz -C "$PKG"

check "install: the binary is executable" \
    "$([ -x "$PKG/skill-log" ] && printf yes || printf no)" "yes"
check "install: the bundled SQLite is installed" \
    "$([ -f "$PKG/lib/libsqlite3.so.0" ] && printf yes || printf no)" "yes"

# ------------------------------------------------------------ --version

out="$("$PKG/skill-log" --version 2>"$SCRATCH/version.err")"
code=$?
check "--version: exits 0" "$code" "0"
check "--version: prints the release version" "$out" "$PKG_TEST_VERSION"
check "--version: prints nothing on stderr" \
    "$(wc -c <"$SCRATCH/version.err" | tr -d ' ')" "0"

# ---------------------------------------------------------- LD_DEBUG proof
#
# The loader must resolve libsqlite3.so.0 from the archive's own lib/,
# not from anywhere in the image.

LD_DEBUG=libs "$PKG/skill-log" --version \
    >"$SCRATCH/ld.out" 2>"$SCRATCH/ld.err"
check "loader: resolves libsqlite3.so.0 from the archive's lib/" \
    "$(grep -c "calling init: $PKG/lib/libsqlite3.so.0" "$SCRATCH/ld.err")" "1"

# ------------------------------------------------------ setup --dry-run
#
# A scratch repo. With git in the image the hook and report directory
# show created; without git they are the named skip.

mkdir -p "$REPO/skills"
if command -v git >/dev/null 2>&1; then
    git -C "$REPO" init -q
    GIT_PRESENT=yes
else
    GIT_PRESENT=no
fi

out="$("$PKG/skill-log" setup --dry-run --repo "$REPO" \
    --skills-dir "$REPO/skills" --db "$REPO/store.db" \
    2>"$SCRATCH/setup.err")"
code=$?
check "setup --dry-run: exits 0" "$code" "0"
check "setup --dry-run: prints nothing on stderr" \
    "$(wc -c <"$SCRATCH/setup.err" | tr -d ' ')" "0"
check "setup --dry-run: prints the machine identity" \
    "$(printf '%s\n' "$out" | grep -c '^machine: ')" "1"
check "setup --dry-run: the store verdict is created" \
    "$(printf '%s\n' "$out" | grep -c '^created  store  ')" "1"
if [ "$GIT_PRESENT" = yes ]; then
    check "setup --dry-run: the hook verdict is created" \
        "$(printf '%s\n' "$out" | grep -c '^created  hook  ')" "1"
    check "setup --dry-run: the report dir verdict is created" \
        "$(printf '%s\n' "$out" | grep -c '^created  report_dir  ')" "1"
else
    check_contains "setup --dry-run: the hook is the named skip" \
        "$out" "skipped  hook  not a git checkout"
    check_contains "setup --dry-run: the report dir is the named skip" \
        "$out" "skipped  report_dir  not a git checkout"
fi
check "setup --dry-run: writes no store" \
    "$(ls "$REPO/store.db" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "setup --dry-run: writes no report directory" \
    "$(ls -d "$REPO/.skill-log" 2>/dev/null | wc -l | tr -d ' ')" "0"

# -------------------------------------------------------------- negative
#
# The bundled copy removed and no system copy anywhere: the run must
# fail with one named line. That proves the positive runs above loaded
# the bundled file because it was the only one there.

cp -a "$PKG" "$NEG"
rm -f "$NEG/lib/libsqlite3.so.0"
out="$("$NEG/skill-log" --version 2>"$SCRATCH/neg.err")"
code=$?
check "negative: a missing bundled SQLite exits 1" "$code" "1"
check "negative: a missing bundled SQLite keeps stdout empty" \
    "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
check_one_line "negative: a missing bundled SQLite is one stderr line" \
    "$(cat "$SCRATCH/neg.err")"
check_contains "negative: a missing bundled SQLite names the cause" \
    "$(cat "$SCRATCH/neg.err")" "skill-log: sqlite unavailable: "
check_absent "negative: a missing bundled SQLite prints no traceback" \
    "$(cat "$SCRATCH/neg.err")" "stack trace"

tally
INNER

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf '==> image %s already present; the run needs no network\n' "$IMAGE"
else
    printf '==> image %s not present; pulling once\n' "$IMAGE"
    docker pull "$IMAGE" || {
        printf 'packaging.sh: cannot pull %s\n' "$IMAGE" >&2
        exit 1
    }
fi

printf '==> container run: archive %s in %s\n' "$base" "$IMAGE"
docker run --rm --pull=never \
    -e PKG_TEST_VERSION="$version" \
    -v "$ARCHIVE:/in/archive.tar.gz:ro" \
    -v "$INNER:/in/inner.sh:ro" \
    -v "$HERE/lib.sh:/in/lib.sh:ro" \
    "$IMAGE" bash /in/inner.sh
container_status=$?

if [ "$container_status" -ne 0 ]; then
    fail "container: every in-container check passed"
else
    pass "container: every in-container check passed"
fi

tally