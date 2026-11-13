#!/usr/bin/env bash
# The packaging test: the release archive installed into a clean
# container.
#
#   tests/packaging.sh
#   tests/packaging.sh --archive dist/skill-log-v1.0.0-x86_64-unknown-linux-gnu.tar.gz
#   tests/packaging.sh --image debian:bookworm-slim
#
# The archive is unpacked into a container that has no toolchain and no
# system SQLite. There `--version` and `setup --dry-run` run against a
# scratch repo, the executable is shown to be statically linked, and a
# store write succeeds — so the archive carries a working tool, not just
# a file.
#
# The old negative case removed the bundled libsqlite3.so.0 and expected
# a named failure: it proved the bundled copy was the only source. A
# static executable has no such source to remove — the SQLite is inside
# it — so the case that replaces it asserts the stronger structural
# fact: the archive carries no shared object at all, and the tool still
# reads and writes its store in a container with no SQLite installed.
#
# The default image is debian:bookworm-slim: no toolchain, no system
# SQLite. Once the image is present the test needs no network (the run
# is --pull=never); a missing image is pulled once, explicitly. Override
# the image with --image or SKILL_LOG_PACKAGING_IMAGE. The release
# workflow runs this same script on ubuntu:22.04.
#
# The image carries no git, so `setup --dry-run`'s repo-scoped artifacts
# are asserted through the named skip ("not a git checkout"); an image
# with git gets the created-verdict assertions instead.
#
# This is not part of scripts/test.sh: it needs docker, so the default
# gate stays offline and fast. Run it directly, and on CI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(dirname "$HERE")" && pwd)"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-packaging}"

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

# Docker binds a host path into the container, and a relative path is
# not a host path: docker resolves a relative source against its own
# working directory and rejects it. The archive is therefore made
# absolute before it is ever handed to `docker -v`.
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

base="$(basename "$ARCHIVE")"
version="${base#skill-log-}"
version="${version%-x86_64-unknown-linux-gnu.tar.gz}"

# ------------------------------------------------------- the packed shape
#
# Exactly the executable and the licence material a redistributor must
# carry. reference/ and tests/ are never shipped (§8), and the listing
# check proves it.

listing="$(tar -tzf "$ARCHIVE" | sort)"
expected="$(printf '%s\n' \
    LICENSE \
    NOTICE-LICENSES/ \
    'NOTICE-LICENSES/LICENSE' \
    'NOTICE-LICENSES/LICENSE-SQLITE' \
    'NOTICE-LICENSES/LICENSE-SQLITE_VEC' \
    THIRD-PARTY-NOTICES.md \
    skill-log | sort)"

check "archive: entries are exactly the executable and the licence material" \
    "$listing" "$expected"
check_absent "archive: no reference/ tree is shipped" "$listing" "reference/"
check_absent "archive: no tests/ is shipped" "$listing" "tests/"
check_absent "archive: no src/ is shipped" "$listing" "src/"
check_absent "archive: no vendor/ is shipped" "$listing" "vendor/"

# The archive carries no shared object: the executable is statically
# linked, so there is nothing for a loader to resolve and nothing for a
# machine to have installed. This is the case that replaced the old
# "remove the bundled SQLite and watch it fail" negative.
shared_objects="$(tar -tzf "$ARCHIVE" | grep -cE '\.so([.0-9]*)?$')"
check "archive: no shared object is shipped" "$shared_objects" "0"

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
# environment: this image has no toolchain and no system SQLite.
set -uo pipefail

# shellcheck disable=SC1091
. /in/lib.sh

PKG=/tmp/pkg
SCRATCH=/tmp/pkg-test
REPO=/tmp/scratch-repo
HOME_DIR=/tmp/home

# ------------------------------------------------- the image is clean

check "image: no Go toolchain" \
    "$(command -v go 2>/dev/null || true)" ""
check "image: no Mojo toolchain" \
    "$(command -v mojo 2>/dev/null || true)" ""
check "image: no system SQLite under /usr/lib" \
    "$(find /usr/lib -name 'libsqlite3.so*' 2>/dev/null | wc -l | tr -d ' ')" "0"
check "image: no system SQLite under /lib" \
    "$(find /lib /lib64 -name 'libsqlite3.so*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# ------------------------------------------------------------- install

mkdir -p "$PKG" "$SCRATCH" "$HOME_DIR"
tar -xzf /in/archive.tar.gz -C "$PKG"

check "install: the binary is executable" \
    "$([ -x "$PKG/skill-log" ] && printf yes || printf no)" "yes"
check "install: the archive carries the licence" \
    "$([ -f "$PKG/LICENSE" ] && printf yes || printf no)" "yes"
check "install: the archive carries the third-party notices" \
    "$([ -f "$PKG/THIRD-PARTY-NOTICES.md" ] && printf yes || printf no)" "yes"

# --------------------------------------------------- the static executable
#
# The loader has nothing to resolve: the SQLite travels inside the
# executable, so the container needs no SQLite of its own.
if command -v ldd >/dev/null 2>&1; then
    report="$(ldd "$PKG/skill-log" 2>&1 || true)"
    if printf '%s\n' "$report" | grep -qi 'not a dynamic executable'; then
        pass "binary: the executable is static"
    else
        fail "binary: the executable is static ($report)"
    fi
else
    if command -v file >/dev/null 2>&1; then
        if file "$PKG/skill-log" | grep -qi 'statically linked'; then
            pass "binary: the executable is static"
        else
            fail "binary: the executable is static"
        fi
    else
        printf 'skip neither ldd nor file is installed: the static check did not run\n'
    fi
fi

check "binary: no shared object sits beside it" \
    "$(find "$PKG" -name '*.so*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# ------------------------------------------------------------ --version

out="$("$PKG/skill-log" --version 2>"$SCRATCH/version.err")"
code=$?
check "--version: exits 0" "$code" "0"
check "--version: prints the release version" "$out" "$PKG_TEST_VERSION"
check "--version: prints nothing on stderr" \
    "$(wc -c <"$SCRATCH/version.err" | tr -d ' ')" "0"

# ------------------------------------------------------ setup --dry-run
#
# A scratch repo. With git in the image the hook and report directory
# show created; without git they are the SPEC's named skip.

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
if [ "$code" -eq 0 ]; then
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
else
    fail "setup --dry-run: exits 0"
    printf '     %s\n' "$(cat "$SCRATCH/setup.err")"
fi

# --------------------------------------------------------- the store works
#
# The case the old negative case was built for: the tool reads and
# writes its store in a container with no SQLite installed. The SQLite
# travels inside the executable, so this succeeds where a dynamically
# linked build would have nothing to load.

out="$(HOME="$HOME_DIR" "$PKG/skill-log" add --skill packaged 2>"$SCRATCH/add.err")"
code=$?
check "store: a write exits 0" "$code" "0"
check "store: a write prints the marker" \
    "$(printf '%s' "$out" | grep -cE '^[^[:space:]]+#1$')" "1"
check "store: a write prints nothing on stderr" \
    "$(wc -c <"$SCRATCH/add.err" | tr -d ' ')" "0"

out="$(HOME="$HOME_DIR" "$PKG/skill-log" show --json 2>"$SCRATCH/show.err")"
code=$?
check "store: a read exits 0" "$code" "0"
check "store: the read finds the row" \
    "$(printf '%s' "$out" | grep -c '"skill":"packaged"')" "1"

# The store is a real SQLite file, read by an ordinary reader when the
# image carries one.
DB="$HOME_DIR/.local/state/skill-log/skills.db"
if command -v sqlite3 >/dev/null 2>&1; then
    check "store: the store file is a SQLite database" \
        "$(sqlite3 "$DB" 'select count(*) from invocations' 2>/dev/null)" "1"
else
    printf 'skip sqlite3 is not installed: the store file was not read directly\n'
fi

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
