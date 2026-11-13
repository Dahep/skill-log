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
# temporary git repositories. The detection reads the working tree the row
# names, so the cases run from inside the repository they created, and the
# cases that care about a *named* worktree pass one.
#
# The opencode adapter's session store is a fake one, built with the
# sqlite3 CLI, so the test never touches the real opencode database.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
BIN="$DIST/skill-log"

SCRATCH="${SCRATCH:-/tmp/opencode/skill-log-context}"

# shellcheck disable=SC1091  # the harness sits beside the suite, not on PATH
. "$HERE/lib.sh"

require_tools git sqlite3 python3

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

# run <args...>: the binary with the sandbox's environment. Output lands
# in $OUT and $ERR, the status in $STATUS.
run() {
    OUT="$("$BIN" "$@" 2>"$SCRATCH/stderr")"
    STATUS=$?
    ERR="$(cat "$SCRATCH/stderr")"
}

# A repository with an origin remote, and a linked worktree of it.
make_repo() {
    # make_repo <dir> [repository name]
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
    git -C "$1" remote add origin \
        "https://user:secret@example.com/owner/${2:-thing}.git"
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
check "the repo is the origin remote's basename" "$(json_field "$OUT" repo)" "thing"
check "the worktree is the toplevel" "$(json_field "$OUT" worktree)" "$REPO"
check "the credentials never reach the row" \
    "$(printf '%s' "$OUT" | grep -c 'secret')" "0"

cd "$SCRATCH/linked" || exit 1
run add --skill detect --dry-run --json
check "a linked worktree gets its own toplevel" \
    "$(json_field "$OUT" worktree)" "$SCRATCH/linked"
check "a linked worktree gets the same repo" "$(json_field "$OUT" repo)" "thing"

cd "$OUTSIDE" || exit 1
run add --skill detect --dry-run --json
check "outside a repository the repo is empty" "$(json_field "$OUT" repo)" ""
check "outside a repository the worktree is empty" "$(json_field "$OUT" worktree)" ""

# A repository without an origin remote falls back to the toplevel
# directory's name.
NO_REMOTE="$SCRATCH/no-remote"
mkdir -p "$NO_REMOTE"
git -C "$NO_REMOTE" init -q
cd "$NO_REMOTE" || exit 1
run add --skill detect --dry-run --json
check "a repository without an origin falls back to the directory name" \
    "$(json_field "$OUT" repo)" "no-remote"

# A credentialed ssh remote loses its userinfo too, and the name is
# still the repository's.
SSH_REPO="$SCRATCH/ssh-repo"
mkdir -p "$SSH_REPO"
git -C "$SSH_REPO" init -q
git -C "$SSH_REPO" remote add origin "ssh://user:secret@example.com/owner/thing.git"
cd "$SSH_REPO" || exit 1
run add --skill detect --dry-run --json
check "an ssh remote's credentials never reach the row" \
    "$(printf '%s' "$OUT" | grep -c 'secret')" "0"
check "an ssh remote's basename is the repo" "$(json_field "$OUT" repo)" "thing"

# ------------------------------------------------- a named worktree wins
#
# `repo` and `worktree` must describe the same checkout. When the caller
# names the worktree, the repository comes from *that* tree, not from the
# process's own directory.

OTHER="$SCRATCH/other-repo"
make_repo "$OTHER" other

cd "$REPO" || exit 1
run add --skill detect --dry-run --json --worktree "$OTHER"
check "the repo follows the named worktree" "$(json_field "$OUT" repo)" "other"
check "the worktree is the named one" "$(json_field "$OUT" worktree)" "$OTHER"

cd "$OUTSIDE" || exit 1
run add --skill detect --dry-run --json --worktree "$OTHER"
check "a named worktree is detected from outside a repository" \
    "$(json_field "$OUT" repo)" "other"

run add --skill detect --dry-run --json --worktree "$SCRATCH/not-a-repo"
check "a path that is not a checkout names no repo" \
    "$(json_field "$OUT" repo)" ""

# A path with a shell metacharacter in it is one argument, not two: the
# detection quotes it. A repository under a name with a single quote is
# the case a naive command string gets wrong.
QUOTED="$SCRATCH/it's repo"
make_repo "$QUOTED" quoted
run add --skill detect --dry-run --json --worktree "$QUOTED"
check "a worktree path with a quote is read as one path" \
    "$(json_field "$OUT" repo)" "quoted"

# ------------------------------------------------------------ precedence

cd "$REPO" || exit 1

run add --skill precedence --dry-run --json --repo flagged
check "the flag wins over the variable and the detection" \
    "$(json_field "$OUT" repo)" "flagged"

OUT="$(SKILL_LOG_REPO=fromenv "$BIN" add --skill precedence --dry-run --json)"
check "the variable wins over the detection" "$(json_field "$OUT" repo)" "fromenv"

OUT="$(SKILL_LOG_REPO=fromenv "$BIN" add --skill precedence --dry-run --json \
    --repo flagged)"
check "the flag wins over the variable" "$(json_field "$OUT" repo)" "flagged"

# Every field's variable is honoured on its own.
OUT="$(SKILL_LOG_HARNESS=env-harness SKILL_LOG_SESSION=env-session \
    SKILL_LOG_PARENT=env-parent SKILL_LOG_MODEL=env/model \
    SKILL_LOG_WORKTREE=/env/worktree SKILL_LOG_PROJECT=env-project \
    SKILL_LOG_T3_THREAD=env-thread \
    "$BIN" add --skill precedence --dry-run --json)"
check "SKILL_LOG_HARNESS fills the harness" "$(json_field "$OUT" harness)" "env-harness"
check "SKILL_LOG_SESSION fills the session" "$(json_field "$OUT" session)" "env-session"
check "SKILL_LOG_PARENT fills the parent" "$(json_field "$OUT" parent)" "env-parent"
check "SKILL_LOG_MODEL fills the model" "$(json_field "$OUT" model)" "env/model"
check "SKILL_LOG_WORKTREE fills the worktree" \
    "$(json_field "$OUT" worktree)" "/env/worktree"
check "SKILL_LOG_PROJECT fills the project" "$(json_field "$OUT" project)" "env-project"
check "SKILL_LOG_T3_THREAD fills the t3 thread" \
    "$(json_field "$OUT" t3_thread)" "env-thread"
check "the machine is the hostname" "$(json_field "$OUT" machine)" "$(hostname)"

# The flag beats the variable, per field.
OUT="$(SKILL_LOG_HARNESS=env-harness SKILL_LOG_MODEL=env/model \
    SKILL_LOG_PROJECT=env-project SKILL_LOG_T3_THREAD=env-thread \
    SKILL_LOG_SESSION=env-session SKILL_LOG_PARENT=env-parent \
    "$BIN" add --skill precedence --dry-run --json \
    --harness flag-harness --model flag/model --project flag-project \
    --t3-thread flag-thread --machine flag-machine --session flag-session \
    --parent flag-parent)"
check "the flag beats SKILL_LOG_HARNESS" "$(json_field "$OUT" harness)" "flag-harness"
check "the flag beats SKILL_LOG_SESSION" "$(json_field "$OUT" session)" "flag-session"
check "the flag beats SKILL_LOG_PARENT" "$(json_field "$OUT" parent)" "flag-parent"
check "the flag beats SKILL_LOG_MODEL" "$(json_field "$OUT" model)" "flag/model"
check "the flag beats SKILL_LOG_PROJECT" "$(json_field "$OUT" project)" "flag-project"
check "the flag beats SKILL_LOG_T3_THREAD" \
    "$(json_field "$OUT" t3_thread)" "flag-thread"
check "the flag beats the detected machine" "$(json_field "$OUT" machine)" "flag-machine"

# ------------------------------------------------------------- adapters

# No adapter runs unasked: with an opencode session in the environment
# and a session store present, the row carries no harness and no model.
OC_HOME="$SCRATCH/oc-home"
mkdir -p "$OC_HOME/.local/share/opencode"
sqlite3 "$OC_HOME/.local/share/opencode/opencode.db" <<'SQL'
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, model TEXT);
INSERT INTO session_v2 (id, model) VALUES
    ('ses_test', '{"id":"kimi-k3","providerID":"opencode"}'),
    ('ses_flag', '{"id":"flag-model","providerID":"flag-provider"}'),
    ('ses_other', '{"id":"other-model","providerID":"other-provider"}'),
    ('ses_nested', '{"meta":{"id":"NESTED","providerID":"nested"},"id":"real","providerID":"p"}'),
    ('ses_bare', 'kimi-k3'),
    ('ses_escaped', '{"id":"\u0061","providerID":"p"}');
SQL

cd "$OUTSIDE" || exit 1
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json)"
check "with no adapter there is no harness" "$(json_field "$OUT" harness)" ""
check "with no adapter there is no model" "$(json_field "$OUT" model)" ""
check "with no adapter there is no session" "$(json_field "$OUT" session)" ""

# The opencode adapter, enabled by the environment variable.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "the opencode adapter fills the harness" "$(json_field "$OUT" harness)" "opencode"
check "the opencode adapter fills the session" "$(json_field "$OUT" session)" "ses_test"
check "the opencode adapter renders the model as provider/id" \
    "$(json_field "$OUT" model)" "opencode/kimi-k3"

# The model resolves after the session (SPEC §4). A session named by the
# flag is the session the row carries, so the model is that session's
# model — and not the model of whatever session the environment names.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_other SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json --session ses_flag)"
check "a named session is the session the row carries" \
    "$(json_field "$OUT" session)" "ses_flag"
check "the model is the named session's model" \
    "$(json_field "$OUT" model)" "flag-provider/flag-model"

# The variable names the session too, and the model follows it.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_other SKILL_LOG_SESSION=ses_flag \
    SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "the variable names the session" "$(json_field "$OUT" session)" "ses_flag"
check "the model is the variable's session's model" \
    "$(json_field "$OUT" model)" "flag-provider/flag-model"

# A session the environment names and the flag does not is the session
# the row carries, and its model is the one that comes with it.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_other SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "the environment names the session when nothing else does" \
    "$(json_field "$OUT" session)" "ses_other"
check "the model is the environment's session's model" \
    "$(json_field "$OUT" model)" "other-provider/other-model"

# The stored model is a JSON object. The id is the top-level one: a
# nested object carrying the same key must not answer for it.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_nested \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "the model reader takes the top-level id" \
    "$(json_field "$OUT" model)" "p/real"

# An escape this reader cannot decode is refused rather than mangled:
# the value falls back to the raw text, which is what the reference does
# for a shape it cannot parse.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_escaped \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "an undecodable escape falls back to the raw value" \
    "$(json_field "$OUT" model)" '{"id":"\u0061","providerID":"p"}'

# A value that is not that shape is passed through unchanged.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_bare \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "a bare model value is passed through" "$(json_field "$OUT" model)" "kimi-k3"

# The same adapter, enabled by the flag.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "--adapter opencode enables the adapter" "$(json_field "$OUT" harness)" "opencode"

# The flag takes a comma-separated list, and may be repeated.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode,t3)"
check "--adapter takes a comma-separated list" "$(json_field "$OUT" harness)" "opencode"
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode --adapter t3)"
check "--adapter may be repeated" "$(json_field "$OUT" harness)" "opencode"

# The machine is always detected: there is no SKILL_LOG_MACHINE.
OUT="$(SKILL_LOG_MACHINE=not-the-machine \
    "$BIN" add --skill adapters --dry-run --json)"
check "SKILL_LOG_MACHINE does not fill the machine" \
    "$(json_field "$OUT" machine)" "$(hostname)"
OUT="$("$BIN" add --skill adapters --dry-run --json --machine named)"
check "--machine names the machine" "$(json_field "$OUT" machine)" "named"

# The machine namespaces every marker (`machine#id`), so a value that
# cannot appear in one is refused at the boundary.
run add --skill machine --dry-run --machine 'box#extra'
check "a machine with a marker separator is a usage error" "$STATUS" "2"
check_one_line "a machine with a marker separator is one line" "$ERR"
check_contains "a machine with a marker separator says why" "$ERR" \
    "cannot contain '#'"

run add --skill machine --dry-run --machine "$(printf 'box\nname')"
check "a machine with a newline is a usage error" "$STATUS" "2"
check_one_line "a machine with a newline is one line" "$ERR"

# The flag beats the adapter's value.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode \
    --model flag/model)"
check "--model beats the adapter" "$(json_field "$OUT" model)" "flag/model"

# The variable beats the adapter's value.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_MODEL=env/model \
    "$BIN" add --skill adapters --dry-run --json --adapter opencode)"
check "SKILL_LOG_MODEL beats the adapter" "$(json_field "$OUT" model)" "env/model"

# The adapter never sets the parent.
OUT="$(HOME="$OC_HOME" OPENCODE_SESSION_ID=ses_test SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "an adapter never sets the parent" "$(json_field "$OUT" parent)" ""

# A missing session store is a blank model, not an error.
OUT="$(HOME="$SCRATCH/no-store-home" OPENCODE_SESSION_ID=ses_test \
    SKILL_LOG_ADAPTERS=opencode \
    "$BIN" add --skill adapters --dry-run --json)"
check "a missing session store is a blank model" "$(json_field "$OUT" model)" ""
check "a missing session store still fills the harness" \
    "$(json_field "$OUT" harness)" "opencode"

# The t3 adapter fills the project from the worktree's path.
T3_HOME="$SCRATCH/t3"
mkdir -p "$T3_HOME/worktrees/myproject/sub"
OUT="$(T3CODE_HOME="$T3_HOME" "$BIN" add --skill adapters --dry-run --json \
    --adapter t3 --worktree "$T3_HOME/worktrees/myproject/sub")"
check "the t3 adapter fills the project" "$(json_field "$OUT" project)" "myproject"
check "the t3 adapter never invents a thread id" "$(json_field "$OUT" t3_thread)" ""

# Without T3CODE_HOME, the T3 home is `$HOME/.t3`.
FALLBACK_HOME="$SCRATCH/t3fallback-home"
mkdir -p "$FALLBACK_HOME/.t3/worktrees/fallback/sub"
OUT="$(HOME="$FALLBACK_HOME" T3CODE_HOME="" \
    "$BIN" add --skill adapters --dry-run --json --adapter t3 \
    --worktree "$FALLBACK_HOME/.t3/worktrees/fallback/sub")"
check "the t3 adapter falls back to HOME/.t3" \
    "$(json_field "$OUT" project)" "fallback"

# Outside T3 there is no project.
OUT="$(T3CODE_HOME="$T3_HOME" "$BIN" add --skill adapters --dry-run --json \
    --adapter t3 --worktree "$OUTSIDE")"
check "the t3 adapter leaves the project empty outside T3" \
    "$(json_field "$OUT" project)" ""

# An unknown adapter is ignored rather than fatal.
run add --skill adapters --dry-run --json --adapter no-such-adapter
check "an unknown adapter is ignored" "$STATUS" "0"

# An unknown flag is a usage error, and it is one line.
run add --skill adapters --no-such-flag
check "an unknown flag exits 2" "$STATUS" "2"
check_one_line "an unknown flag is one stderr line" "$ERR"

# -------------------------------------------------------------- stdin

cd "$OUTSIDE" || exit 1
OUT="$(printf 'the problem from a pipe\n' \
    | "$BIN" add --skill stdin --dry-run --json --problem -)"
check "--problem - reads the text from stdin" "$(json_problem "$OUT")" \
    "the problem from a pipe"

printf 'the problem from a file\n' >"$SCRATCH/problem.txt"
OUT="$("$BIN" add --skill stdin --dry-run --json --problem - \
    <"$SCRATCH/problem.txt")"
check "--problem - reads the text from a file" "$(json_problem "$OUT")" \
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

# --------------------------------------------------------------- json

# The writer escapes; the reader here parses. A value carrying a quote
# round-trips, which a `sed` field reader cannot do.
OUT="$("$BIN" add --skill 'a"b' --dry-run --json)"
check "an escaped quote round-trips through the JSON" \
    "$(json_field "$OUT" skill)" 'a"b'

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

# ----------------------------------------------------------------- report

tally
