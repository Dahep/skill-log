#!/usr/bin/env bash
# The context test: the fields a row carries and where they come from.
#
#   tests/context.sh
#
# It exercises ADR-0002's precedence chain against the built artifact:
# the explicit flag, then the field's SKILL_LOG_* variable, then an
# enabled adapter, then the built-in detection — one field at a time.
#
# Everything runs in a sandbox: a temporary HOME, a temporary store, and
# temporary git repositories. The detection reads the *current working
# directory*, so the cases that care about it run from inside a
# repository they created, and the cases that care about "outside a
# repository" run from a directory that is not one.
#
# The opencode adapter's session store is a fake one, built with the
# sqlite3 CLI, so the test never touches the real opencode database.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-context}"

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
    # check <name> <actual> <expected>
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

check_contains() {
    # check_contains <name> <actual> <needle>
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (expected to contain '$3', got '$2')" ;;
    esac
}

if [ ! -x "$BIN" ]; then
    printf 'context.sh: %s is missing; run scripts/build.sh first\n' "$BIN" >&2
    exit 1
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home"

HOME_DIR="$SCRATCH/home"

# The sandbox's HOME, so nothing reaches the real opencode store, the
# real ~/.t3, or the real skill-log store.
export HOME="$HOME_DIR"
unset XDG_STATE_HOME SKILL_LOG_DB
unset SKILL_LOG_ADAPTERS SKILL_LOG_HARNESS SKILL_LOG_SESSION
unset SKILL_LOG_PARENT SKILL_LOG_MODEL SKILL_LOG_REPO SKILL_LOG_WORKTREE
unset SKILL_LOG_PROJECT SKILL_LOG_T3_THREAD SKILL_LOG_MACHINE
unset OPENCODE_SESSION_ID T3CODE_HOME

DB="$HOME_DIR/.local/state/skill-log/skills.db"

# The context of the row `add --dry-run --json` would write, as one
# flat JSON object. The helper reads one field out of it.
field() {
    # field <json> <key>
    printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

# The one problem the row carries, as text. The problems are an array,
# so the string-field helper cannot read them.
problem() {
    # problem <json>
    printf '%s' "$1" | sed -n 's/.*"problems":\["\([^"]*\)"\].*/\1/p'
}

# run <args...>: the binary with the sandbox's environment. Output lands
# in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# The number of lines on stderr. A failure is exactly one line.
err_lines() {
    printf '%s\n' "$ERR" | grep -c . || true
}

# A repository with an origin remote, and a linked worktree of it.
make_repo() {
    # make_repo <dir>
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
    git -C "$1" remote add origin "https://user:secret@example.com/owner/thing.git"
    printf 'content\n' >"$1/file.txt"
    git -C "$1" add -A
    git -C "$1" commit -qm "initial"
}

# ------------------------------------------------- repository detection

REPO="$SCRATCH/repo"
make_repo "$REPO"

# The linked worktree gets its own toplevel, not the main checkout's.
git -C "$REPO" worktree add -q "$SCRATCH/linked" -b linked 2>/dev/null

# Outside a repository: a plain directory that is not one.
OUTSIDE="$SCRATCH/outside"
mkdir -p "$OUTSIDE"

cd "$REPO" || exit 1
run add --skill detect --dry-run --json
check "add --dry-run exits 0" "$STATUS" "0"
check "the repo is the origin remote's basename" "$(field "$OUT" repo)" "thing"
check "the worktree is the toplevel" "$(field "$OUT" worktree)" "$REPO"
check "the credentials never reach the row" \
    "$(printf '%s' "$OUT" | grep -c 'secret')" "0"

cd "$SCRATCH/linked" || exit 1
run add --skill detect --dry-run --json
check "a linked worktree gets its own toplevel" "$(field "$OUT" worktree)" \
    "$SCRATCH/linked"
check "a linked worktree gets the same repo" "$(field "$OUT" repo)" "thing"

cd "$OUTSIDE" || exit 1
run add --skill detect --dry-run --json
check "outside a repository the repo is empty" "$(field "$OUT" repo)" ""
check "outside a repository the worktree is empty" "$(field "$OUT" worktree)" ""

# A repository without an origin remote falls back to the toplevel
# directory's name.
NO_REMOTE="$SCRATCH/no-remote"
mkdir -p "$NO_REMOTE"
git -C "$NO_REMOTE" init -q
cd "$NO_REMOTE" || exit 1
run add --skill detect --dry-run --json
check "a repository without an origin falls back to the directory name" \
    "$(field "$OUT" repo)" "no-remote"

# ------------------------------------------------------------ precedence

cd "$REPO" || exit 1

run add --skill precedence --dry-run --json --repo flagged
check "the flag wins over the variable and the detection" \
    "$(field "$OUT" repo)" "flagged"

OUT="$(SKILL_LOG_REPO=fromenv "$BIN" add --skill precedence --dry-run --json)"
check "the variable wins over the detection" "$(field "$OUT" repo)" "fromenv"

OUT="$(SKILL_LOG_REPO=fromenv "$BIN" add --skill precedence --dry-run --json \
    --repo flagged)"
check "the flag wins over the variable" "$(field "$OUT" repo)" "flagged"

# Every field's variable is honoured on its own.
OUT="$(SKILL_LOG_HARNESS=env-harness SKILL_LOG_SESSION=env-session \
    SKILL_LOG_PARENT=env-parent SKILL_LOG_MODEL=env/model \
    SKILL_LOG_WORKTREE=/env/worktree SKILL_LOG_PROJECT=env-project \
    SKILL_LOG_T3_THREAD=env-thread \
    "$BIN" add --skill precedence --dry-run --json)"
check "SKILL_LOG_HARNESS fills the harness" "$(field "$OUT" harness)" "env-harness"
check "SKILL_LOG_SESSION fills the session" "$(field "$OUT" session)" "env-session"
check "SKILL_LOG_PARENT fills the parent" "$(field "$OUT" parent)" "env-parent"
check "SKILL_LOG_MODEL fills the model" "$(field "$OUT" model)" "env/model"
check "SKILL_LOG_WORKTREE fills the worktree" "$(field "$OUT" worktree)" "/env/worktree"
check "SKILL_LOG_PROJECT fills the project" "$(field "$OUT" project)" "env-project"
check "SKILL_LOG_T3_THREAD fills the t3 thread" "$(field "$OUT" t3_thread)" "env-thread"
check "the machine is the hostname" "$(field "$OUT" machine)" "$(hostname)"

# The flag beats the variable, per field.
OUT="$(SKILL_LOG_HARNESS=env-harness SKILL_LOG_MODEL=env/model \
    SKILL_LOG_PROJECT=env-project SKILL_LOG_T3_THREAD=env-thread \
    SKILL_LOG_SESSION=env-session SKILL_LOG_PARENT=env-parent \
    "$BIN" add --skill precedence --dry-run --json \
    --harness flag-harness --model flag/model --project flag-project \
    --t3-thread flag-thread --machine flag-machine --session flag-session \
    --parent flag-parent)"
check "the flag beats SKILL_LOG_HARNESS" "$(field "$OUT" harness)" "flag-harness"
check "the flag beats SKILL_LOG_SESSION" "$(field "$OUT" session)" "flag-session"
check "the flag beats SKILL_LOG_PARENT" "$(field "$OUT" parent)" "flag-parent"
check "the flag beats SKILL_LOG_MODEL" "$(field "$OUT" model)" "flag/model"
check "the flag beats SKILL_LOG_PROJECT" "$(field "$OUT" project)" "flag-project"
check "the flag beats SKILL_LOG_T3_THREAD" "$(field "$OUT" t3_thread)" "flag-thread"
check "the flag beats the detected machine" "$(field "$OUT" machine)" "flag-machine"

# ------------------------------------------------------------- adapters

# No adapter runs unasked: with an opencode session in the environment
# and a session store present, the row carries no harness and no model.
OC_HOME="$SCRATCH/oc-home"
mkdir -p "$OC_HOME/.local/share/opencode"
sqlite3 "$OC_HOME/.local/share/opencode/opencode.db" <<'SQL'
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, model TEXT);
INSERT INTO session_v2 (id, model) VALUES
    ('ses_test', '{"id":"kimi-k3","providerID":"opencode"}');
SQL

cd "$OUTSIDE" || exit 1
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json)"
check "with no adapter there is no harness" "$(field "$OUT" harness)" ""
check "with no adapter there is no model" "$(field "$OUT" model)" ""
check "with no adapter there is no session" "$(field "$OUT" session)" ""

# The opencode adapter, enabled by the environment variable.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "the opencode adapter fills the harness" "$(field "$OUT" harness)" "opencode"
check "the opencode adapter fills the session" "$(field "$OUT" session)" "ses_test"
check "the opencode adapter renders the model as provider/id" \
    "$(field "$OUT" model)" "opencode/kimi-k3"

# The same adapter, enabled by the flag.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "--adapter opencode enables the adapter" "$(field "$OUT" harness)" "opencode"

# The flag takes a comma-separated list, and may be repeated.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode,t3)"
check "--adapter takes a comma-separated list" "$(field "$OUT" harness)" "opencode"
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode --adapter t3)"
check "--adapter may be repeated" "$(field "$OUT" harness)" "opencode"

# The machine is always detected: there is no SKILL_LOG_MACHINE.
OUT="$(SKILL_LOG_MACHINE=not-the-machine \
    "$BIN" add --skill adapters --dry-run --json)"
check "SKILL_LOG_MACHINE does not fill the machine" "$(field "$OUT" machine)" \
    "$(hostname)"
OUT="$("$BIN" add --skill adapters --dry-run --json --machine named)"
check "--machine names the machine" "$(field "$OUT" machine)" "named"

# The flag beats the adapter's value.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode \
    --model flag/model)"
check "--model beats the adapter" "$(field "$OUT" model)" "flag/model"

# The variable beats the adapter's value.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_MODEL=env/model \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "SKILL_LOG_MODEL beats the adapter" "$(field "$OUT" model)" "env/model"

# The adapter never sets the parent.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "an adapter never sets the parent" "$(field "$OUT" parent)" ""

# A missing session store is a blank model, not an error.
OUT="$(HOME="$SCRATCH/no-store-home" OPENCODE_SESSION_ID=ses_test \
    SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "a missing session store is a blank model" "$(field "$OUT" model)" ""
check "a missing session store still fills the harness" \
    "$(field "$OUT" harness)" "opencode"

# The t3 adapter fills the project from the worktree's path.
T3_HOME="$SCRATCH/t3"
mkdir -p "$T3_HOME/worktrees/myproject/sub"
OUT="$(T3CODE_HOME="$T3_HOME" "$BIN" add --skill adapters --dry-run --json \
    --adapter t3 --worktree "$T3_HOME/worktrees/myproject/sub")"
check "the t3 adapter fills the project" "$(field "$OUT" project)" "myproject"
check "the t3 adapter never invents a thread id" "$(field "$OUT" t3_thread)" ""

# Outside T3 there is no project.
OUT="$(T3CODE_HOME="$T3_HOME" "$BIN" add --skill adapters --dry-run --json \
    --adapter t3 --worktree "$OUTSIDE")"
check "the t3 adapter leaves the project empty outside T3" \
    "$(field "$OUT" project)" ""

# An unknown adapter is ignored rather than fatal.
OUT="$("$BIN" add --skill adapters --dry-run --json --adapter no-such-adapter)"
check "an unknown adapter is ignored" "$STATUS" "0"

# An unknown flag is a usage error, and it is one line.
run add --skill adapters --no-such-flag
check "an unknown flag exits 2" "$STATUS" "2"
check "an unknown flag is one stderr line" "$(err_lines)" "1"

# -------------------------------------------------------------- stdin

cd "$OUTSIDE" || exit 1
OUT="$(printf 'the problem from a pipe\n' \
    | "$BIN" add --skill stdin --dry-run --json --problem -)"
check "--problem - reads the text from stdin" "$(problem "$OUT")" \
    "the problem from a pipe"

printf 'the problem from a file\n' >"$SCRATCH/problem.txt"
OUT="$("$BIN" add --skill stdin --dry-run --json --problem - \
    <"$SCRATCH/problem.txt")"
check "--problem - reads the text from a file" "$(problem "$OUT")" \
    "the problem from a file"

# On a terminal there is nothing to read, and the command must not wait.
#
# The redirect lives inside the `script` command string: `script` runs
# the command on a pty, and a pty is one stream, so a redirect outside
# the string would capture the pty itself rather than the command's
# stderr.
if command -v script >/dev/null 2>&1; then
    script -qec "$BIN add --skill stdin --dry-run --problem - 2>$SCRATCH/tty.err" \
        /dev/null >"$SCRATCH/tty.out"
    TTY_STATUS=$?
    check "--problem - on a terminal exits 2" "$TTY_STATUS" "2"
    check "--problem - on a terminal says why" \
        "$(grep -c 'stdin is a terminal' "$SCRATCH/tty.err")" "1"
else
    printf 'skip script is not installed: the terminal case did not run\n'
fi

# ---------------------------------------------------------------- rows

cd "$REPO" || exit 1
run add --skill rows --repo therow --harness claude --model openai/gpt
check "a write with context exits 0" "$STATUS" "0"
check "the row carries the repo" \
    "$(sqlite3 "$DB" 'select repo from invocations order by id desc limit 1')" \
    "therow"
check "the row carries the harness" \
    "$(sqlite3 "$DB" 'select harness from invocations order by id desc limit 1')" \
    "claude"
check "the row carries the model" \
    "$(sqlite3 "$DB" 'select model from invocations order by id desc limit 1')" \
    "openai/gpt"
check "the row carries the machine" \
    "$(sqlite3 "$DB" 'select machine from invocations order by id desc limit 1')" \
    "$(hostname)"

# ------------------------------------------------------------------ help

run add --help
check "add --help exits 0" "$STATUS" "0"
for flag in --harness --session --parent --model --repo --worktree --project \
    --t3-thread --machine --adapter; do
    check_contains "add --help lists $flag" "$OUT" "$flag"
done
check_contains "add --help keeps the non-idempotency note" "$OUT" \
    "not idempotent"
check "add --help ends with 2 to 4 real invocations" \
    "$(printf '%s' "$OUT" | sed -n '/^examples:$/,$p' | grep -c '^  ')" "4"

# --------------------------------------------------------------- report

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
