#!/usr/bin/env bash

# test-skill-log.sh — sandbox acceptance harness for bin/skill-log (the model
# column: db migration, the local-store-only detect chain, defaults).
#
# Stages a fake HOME under a mktemp sandbox; the real ~/.local/state and
# ~/.local/share/opencode stores are never a write or read target (the sandbox
# HOME answers every Path.home() lookup).
#
# Run: scripts/test-skill-log.sh
# Exit: 0 = every case passed, 1 = one or more cases failed.
# Idempotent: fresh mktemp sandbox per run, removed on exit; safe to re-run.

set -u

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$WORK/bin/skill-log"

if [ -d /tmp/opencode ]; then
    BASE="$(mktemp -d /tmp/opencode/skill-log-test-XXXXXX)"
else
    BASE="$(mktemp -d)"
fi
S="$BASE/stage"
trap 'rm -rf "$BASE" 2>/dev/null' EXIT

REAL_HOME="$HOME"
case "$BASE" in
    "$REAL_HOME" | "$REAL_HOME"/*)
        echo "refusing: sandbox $BASE is inside the real HOME" >&2
        exit 1
        ;;
esac
export HOME="$S/home"
case "$HOME" in
    "$S"/*) ;;
    *)
        echo "refusing: HOME $HOME is not inside the sandbox $S" >&2
        exit 1
        ;;
esac
if [ ! -f "$TOOL" ]; then
    echo "refusing: $WORK does not look like the dotfiles repo under test" >&2
    exit 1
fi
export PATH="/usr/bin:/bin"
PYTHON="$(command -v python3)"
# Every case-level invocation: unset the real machine's session/API context
# so auto-detect answers only from the fixture inputs.
strip_env() {
    # XDG_STATE_HOME is unset for the same reason HOME is redirected: the
    # tool's default db path honors it before Path.home(), so a host that
    # sets it would otherwise point the sandbox at the real log.
    env -u OPENCODE_SESSION_ID -u T3CODE_HOST -u T3CODE_PORT \
        -u XDG_STATE_HOME "$@"
}
PASS=0
FAIL=0

say() { printf '\n=== %s ===\n' "$1"; }
ok() { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# assert_eq <case> <label> <got> <want>
assert_eq() {
    if [ "$3" = "$4" ]; then
        ok "$2"
    else
        fail "$1" "$2: got [$3], want [$4]"
    fi
}

count_rows() {
    "$PYTHON" -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('SELECT COUNT(*) FROM invocations').fetchone()[0])" "$1"
}

# --- case 1: migration — a v1 log db (no model column) ingests new rows ------
say "case 1: migration of a v1 db (invocations without model)"
mkdir -p "$S/db"
DBT="$S/db"

# mkopdb <session-id> <model-json> [...]: a minimal opencode session store
# ($HOME-managed, so it lands in the sandbox) with the named sessions and
# their model JSON in the exact session_v2 shape skill-log reads.
mkopdb() {
    "$PYTHON" - "$HOME/.local/share/opencode/opencode.db" "$@" <<'EOF'
import sqlite3, sys
from pathlib import Path

db = Path(sys.argv[1])
db.parent.mkdir(parents=True, exist_ok=True)
con = sqlite3.connect(str(db))
con.execute("CREATE TABLE IF NOT EXISTS session_v2 (id TEXT PRIMARY KEY, model TEXT)")
pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
for sid, model_json in pairs:
    con.execute(
        "INSERT OR REPLACE INTO session_v2 (id, model) VALUES (?, ?)",
        (sid, model_json),
    )
con.commit()
con.close()
EOF
}

# mkv1db <path> [seed-skill]: a pre-model (v1) skill-log db — whatever a
# pre-delta run wrote: invocations without the model column, problems
# table present, one seeded invocation row when [seed-skill] is given.
mkv1db() {
    "$PYTHON" - "$@" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    CREATE TABLE invocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        skill TEXT NOT NULL,
        project TEXT NOT NULL DEFAULT '',
        t3_thread TEXT NOT NULL DEFAULT '',
        opencode_thread TEXT NOT NULL DEFAULT '',
        worktree TEXT NOT NULL DEFAULT '',
        machine TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS problems (
        invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        problem TEXT NOT NULL,
        PRIMARY KEY (invocation_id, ordinal)
    );
""")
if len(sys.argv) > 2 and sys.argv[2]:
    con.execute(
        "INSERT INTO invocations (ts, skill)"
        " VALUES ('2026-01-01T00:00:00+00:00', ?)",
        (sys.argv[2],),
    )
con.commit()
con.close()
EOF
}

V1DB="$DBT/v1.db"
if ! mkv1db "$V1DB" old-skill; then
    fail "migration" "fixture db creation failed"
    exit 1
fi
out="$(strip_env "$TOOL" add --skill new-skill --model prov-a/m-old --db "$V1DB" --json)"
assert_eq "migration" "add on a v1 db exits 0" "$?" "0"
old_model="$(strip_env "$TOOL" show --skill old-skill --db "$V1DB" --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')"
new_model="$(strip_env "$TOOL" show --skill new-skill --last 1 --db "$V1DB" --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')"
assert_eq "migration" "pre-migration row keeps model=''" "$old_model" ""
assert_eq "migration" "post-migration row carries --model" "$new_model" "prov-a/m-old"
strip_env "$TOOL" add --skill new-skill --model prov-a/m-old --db "$V1DB" >/dev/null
assert_eq "migration" "second add lands a third row; no schema re-loop" "$(count_rows "$V1DB")" "3"

# --- case 2: auto-detect from the local opencode store -----------------------
say "case 2: auto-detect reads the local opencode session's model"
mkopdb ses_fixture '{"id": "m-test", "providerID": "prov-x"}'
out="$(env -u T3CODE_HOST -u T3CODE_PORT OPENCODE_SESSION_ID=ses_fixture \
    "$TOOL" add --skill probed-skill --db "$DBT/c2.db" --json)"
assert_eq "local-detect" "model filled from the session record" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    "prov-x/m-test"
out="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill anon-skill --db "$DBT/c2.db" --json)"
assert_eq "local-detect" "no session id -> model empty" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    ""
out="$(env -u T3CODE_HOST -u T3CODE_PORT OPENCODE_SESSION_ID=ses_missing \
    "$TOOL" add --skill unknown-skill --db "$DBT/c2.db" --json)"
assert_eq "local-detect" "unknown session -> model empty" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    ""

# --- case 3: no local store at all -------------------------------------------
say "case 3: model stays empty when the session is not in any local store"
rm -rf "$HOME/.local/share/opencode"
out="$(OPENCODE_SESSION_ID=ses_remote T3CODE_HOST=fake-api-host T3CODE_PORT=9999 \
    "$TOOL" add --skill remote-skill --db "$DBT/c3.db" --json)"
# Deliberate: the model is a local-store-only fact. A session id that this
# machine's opencode db cannot answer (a delegated thread on another
# machine, or no store at all) lands blank; the docstring and the skill doc
# say exactly that, and --model fills manually when the caller knows.
assert_eq "no-local-store" "foreign session -> model empty" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    ""
assert_eq "no-local-store" "unknown env session + --opencode-thread of a known one keys on the row's session" \
    "$(OPENCODE_SESSION_ID=ses_unknown T3CODE_HOST=fake-api-host T3CODE_PORT=9999 \
        "$TOOL" add --skill keyed-skill --opencode-thread ses_fixture --db "$DBT/c3.db" --json |
        "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    ""
# Restore a store that WOULD answer ses_fixture, so the --model asserts
# bite: if detection still ran, it would answer prov-x/m-test, not the
# override the row must carry.
mkopdb ses_fixture
out="$(OPENCODE_SESSION_ID=ses_fixture T3CODE_HOST=fake-api-host T3CODE_PORT=9999 \
    "$TOOL" add --skill override-skill --model prov-m/m-fix --db "$DBT/c3.db" --json)"
assert_eq "no-local-store" "--model wins over a reachable detection answer" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    "prov-m/m-fix"
out="$(OPENCODE_SESSION_ID=ses_fixture T3CODE_HOST=fake-api-host T3CODE_PORT=9999 \
    "$TOOL" add --skill override-skill --model prov-m/m-fix --db "$DBT/c3.db" --dry-run --json)"
assert_eq "no-local-store" "dry run with --model keeps the same override" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    "prov-m/m-fix"

# --- case 4: read paths on a pre-migration db --------------------------------
say "case 4: reads of a v1 db do not crash or lie"
V1R="$DBT/v1-read.db"
mkv1db "$V1R" legacy-skill
assert_eq "read-v1" "show on a pre-migration db exits 0 with model=''" \
    "$(strip_env "$TOOL" show --db "$V1R" --json |
        "$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['model'], d['skill'])")" \
    " legacy-skill"
assert_eq "read-v1" "plain stats on this (show-migrated) db still works" \
    "$(strip_env "$TOOL" stats --db "$V1R" --json | wc -l)" "1"
# The first read migrated the writable v1 db, so --by-model now works and
# reports the blank model the pre-migration rows carry.
assert_eq "read-v1" "--by-model on a just-migrated db exits 0, one blank-model row" \
    "$(strip_env "$TOOL" stats --db "$V1R" --by-model --json | wc -l)" "1"
# A read-only snapshot copy cannot migrate; --by-model fails with the hint
# and --by-model absent degrades without a traceback (the dict guard path
# the spec named, exercised on the same forbidden-to-migrate copy).
V1RO="$DBT/v1-ro.db"
mkv1db "$V1RO" ro-skill
chmod 400 "$V1RO"
out="$(strip_env "$TOOL" stats --db "$V1RO" --by-model --json 2>&1 >/dev/null)"
assert_eq "read-v1" "read-only db: --by-model fails with the migration hint" \
    "$(printf '%s' "$out" | head -c 10)" \
    "skill-log:"
assert_eq "read-v1" "read-only db: --by-model exits 1" \
    "$(strip_env "$TOOL" stats --db "$V1RO" --by-model >/dev/null 2>&1; echo $?)" \
    "1"
# While the copy is still read-only: show later on it does not traceback
# either — the dict guard renders the missing column values as blanks.
assert_eq "read-v1" "read-only db: show degrades, never tracebacks" \
    "$(strip_env "$TOOL" show --db "$V1RO" --json 2>&1 >/dev/null; echo $?)" \
    "0"
assert_eq "read-v1" "read-only db: show still reports the row with blank model" \
    "$(strip_env "$TOOL" show --db "$V1RO" --json |
        "$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['model'], d['skill'])")" \
    " ro-skill"
chmod 644 "$V1RO"
# A corrupt --db points at the named failure, not a bare traceback.
CORRUPT="$DBT/corrupt.db"
printf 'not a sqlite file at all' > "$CORRUPT"
out="$(strip_env "$TOOL" stats --db "$CORRUPT" --by-model 2>&1 >/dev/null)"
assert_eq "read-v1" "corrupt db: --by-model names the corruption, exit 1" \
    "$(printf '%s' "$out" | head -c 10)/$(strip_env "$TOOL" stats --db "$CORRUPT" --by-model >/dev/null 2>&1; echo $?)" \
    "skill-log:/1"
out="$(strip_env "$TOOL" show --db "$CORRUPT" --json 2>/dev/null)"
assert_eq "read-v1" "corrupt db: --json stays an empty parseable stream" \
    "$(printf '%s' "$out" | wc -c)" "0"
# --- case 5: show/stats surface ----------------------------------------------
say "case 5: show/stats expose the column without breaking default shape"
C4="$DBT/c4.db"
env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill s1 --model prov-a/m-1 --db "$C4" >/dev/null
env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill s1 --db "$C4" >/dev/null
env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill s1 --problem "p" --db "$C4" >/dev/null
assert_eq "show-json" "oldest row keeps its explicit model" \
    "$(strip_env "$TOOL" show --db "$C4" --json | tail -n1 |
        "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    "prov-a/m-1"
table="$(strip_env "$TOOL" show --db "$C4" | head -n1)"
case "$table" in
    *"model"*) ok "show-table" ;;
    *) fail "show-table" "model column missing from the table header" ;;
esac
plain="$(strip_env "$TOOL" stats --db "$C4" --json)"
assert_eq "stats-default" "plain stats groups one (skill) row" \
    "$(printf '%s\n' "$plain" | wc -l)" "1"
case "$plain" in
    *'"model"'*) fail "stats-default" "model leaked into the default grouping" ;;
    *) ok "stats-default" ;;
esac
rows="$(strip_env "$TOOL" stats --db "$C4" --by-model --json)"
assert_eq "stats-by-model" "two (skill, model) rows for two models" \
    "$(printf '%s\n' "$rows" | wc -l)" "2"
assert_eq "stats-by-model" "every row carries the model key" \
    "$(printf '%s' "$rows" | "$PYTHON" -c 'import json,sys; r=[json.loads(l) for l in sys.stdin]; print(all("model" in x for x in r))')" \
    "True"
rate="$(strip_env "$TOOL" stats --db "$C4" | grep -c 'problems/invocation')"
assert_eq "stats-table-default" "default table keeps the rate column" "$rate" "1"

# --- case 6: the migration race, made deterministic --------------------------
say "case 6: parallel first-write on a v1 db — forced collision, then real pair"
PDB="$DBT/v1-par.db"
mkv1db "$PDB"
# Deterministic collision: drive ensure_columns directly with every thread
# told the column is missing, so the ALTERs must collide; a non-tolerant
# implementation loses a thread here every time, not only when the real
# race window happens to fire.
if ! "$PYTHON" - "$PDB" "$TOOL" <<'EOF'
import importlib.util, sqlite3, sys, threading

db_path, tool_path = sys.argv[1], sys.argv[2]
from importlib import machinery

spec = importlib.util.spec_from_file_location(
    "skill_log", tool_path, loader=machinery.SourceFileLoader("skill_log", tool_path)
)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

original = mod.has_column
# Every thread's FIRST schema check lies "column missing" (the race
# window); the duplicate-column tolerance's own re-check must see the
# truth, so only the first call per thread is spoofed. The per-column
# loop means the lie hits the first column in KNOWN_COLUMNS ("model")
# and the truth governs "parent" — both ALTERs and both tolerance paths
# are exercised.
state = threading.local()


def lying_first(conn: sqlite3.Connection, name: str) -> bool:
    if not getattr(state, "lied", False):
        state.lied = True
        return False
    return original(conn, name)


mod.has_column = lying_first

errors = []
barrier = threading.Barrier(8)

def attempt() -> None:
    con = sqlite3.connect(db_path, timeout=30)
    try:
        barrier.wait()
        mod.ensure_columns(con)
    except BaseException as exc:  # noqa: BLE001 - the case collects
        errors.append(exc)
    finally:
        con.close()

threads = [threading.Thread(target=attempt) for _ in range(8)]
for t in threads:
    t.start()
for t in threads:
    t.join()

mod.has_column = original
con = sqlite3.connect(db_path)
owned = {r[1] for r in con.execute("PRAGMA table_info(invocations)")}
con.close()
want = {"model", "parent"}
if errors or not want.issubset(owned):
    sys.exit(
        "race failed: errors=%r missing=%r"
        % (errors[:3], sorted(want - owned))
    )
EOF
then
  fail "case 6 harness crashed (python driver)"
fi
# The real-world pair underneath the forced case (keeps the shell-path
# sanity: full add processes, WAL journaling, actual file locks).
strip_env "$TOOL" add --skill race-a --model prov-p/m-a --db "$PDB" >/dev/null &
race_a=$!
strip_env "$TOOL" add --skill race-b --model prov-p/m-b --db "$PDB" >/dev/null &
race_b=$!
race_ok="1"
wait "$race_a" || race_ok="0"
wait "$race_b" || race_ok="0"
assert_eq "concurrent" "both adds succeed" "$race_ok" "1"
assert_eq "concurrent" "both rows landed" "$(count_rows "$PDB")" "2"

# --- case 7: --dry-run writes nothing ----------------------------------------
say "case 7: --dry-run previews and writes nothing"
C5="$DBT/c5.db"
out="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill dry --model prov-a/m-dry --dry-run --db "$C5" --json)"
assert_eq "dry-run" "preview shows the model" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["model"])')" \
    "prov-a/m-dry"
if [ -e "$C5" ]; then
    fail "dry-run" "db file was created by a dry run"
else
    ok "dry-run-nodb"
fi

# --- case 8: --parent rides end to end ---------------------------------------
say "case 8: --parent lands on the row and reads back"
C6="$DBT/c6.db"
out="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill research --parent thread_abc123 --db "$C6" --json)"
assert_eq "parent" "add --json echoes the parent" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["parent"])')" \
    "thread_abc123"
readback="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" show --db "$C6" --last 1 --json | "$PYTHON" -c \
    'import json,sys; print(json.loads(sys.stdin.read())["parent"])')"
assert_eq "parent" "show --json reads the parent back" "$readback" "thread_abc123"
table="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" show --db "$C6" --last 1)"
case "$table" in
    *thread_abc123*) ok "parent-table" ;;
    *) fail "parent" "show table lacks the parent cell" ;;
esac

# --- case 9: read-only snapshot that has model but not parent ------------------
say "case 9: read-only model-bearing db without parent still serves --by-model"
C7="$DBT/c7.db"
if ! "$PYTHON" - "$C7" <<'EOF'
import sqlite3, sys
import os
con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    CREATE TABLE invocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        skill TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT '',
        project TEXT NOT NULL DEFAULT '',
        t3_thread TEXT NOT NULL DEFAULT '',
        opencode_thread TEXT NOT NULL DEFAULT '',
        worktree TEXT NOT NULL DEFAULT '',
        machine TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS problems (
        invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        problem TEXT NOT NULL,
        PRIMARY KEY (invocation_id, ordinal)
    );
    INSERT INTO invocations (ts, skill, model)
        VALUES ('2026-01-01T00:00:00+00:00', 'x', 'prov-a/m-1');
""")
con.commit(); con.close()
os.chmod(sys.argv[1], 0o444)
EOF
then
  fail "ro-model" "case 9 fixture creation failed"
  exit 1
fi
# The migration to add parent fails read-only, but the schema's own verdict
# on the model column must survive: --by-model serves the slice, not the
# false "no model column yet" hint.
out="$(env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" stats --db "$C7" --by-model 2>/tmp/sk7err)"
st=$?
assert_eq "ro-model" "by-model exits 0 on un-migratable snapshot" "$st" "0"
assert_eq "ro-model" "by-model names only this db's models" \
    "$(printf '%s' "$out" | head -2 | tail -1 | tr -s ' ')" \
    "x prov-a/m-1 1 0 0 0 0"
# The same snapshot has no fix column, and it cannot be migrated read-only:
# plain stats must still read the row and report resolved as 0, never the
# "no invocations logged yet" silence over a populated log.
out="$(strip_env "$TOOL" stats --db "$C7")"
case "$out" in
    "skill "*)
        assert_eq "ro-model" "plain stats reads a db with no fix column" \
            "$(printf '%s' "$out" | tail -1 | tr -s ' ')" \
            "x 1 0 0 0 0" ;;
    *) fail "ro-model" "plain stats on a fix-less snapshot lied: $out" ;;
esac
assert_eq "ro-model" "a fix-less snapshot never reports the empty message" \
    "$(strip_env "$TOOL" stats --db "$C7" --json | wc -l)" "1"
chmod 644 "$C7"

# --- case 10: a busy first attempt is retried, not lost ----------------------
say "case 10: an add survives a transient lock (retry, one row)"
C8="$DBT/c8.db"
if ! "$PYTHON" - "$C8" "$TOOL" <<'EOF'
import importlib.util, sqlite3, sys
from importlib import machinery

db, tool = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "skill_log_retry", tool, loader=machinery.SourceFileLoader("skill_log_retry", tool)
)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

real = mod.write_conn
calls = {"n": 0}


def flaky(path, timeout=30):
    calls["n"] += 1
    if calls["n"] == 1:
        raise sqlite3.OperationalError("database is locked")
    return real(path, timeout=timeout)


mod.write_conn = flaky
row = {
    "ts": "2026-01-01T00:00:00+00:00",
    "skill": "retry",
    "parent": "",
    "model": "",
    "project": "",
    "t3_thread": "",
    "opencode_thread": "",
    "worktree": "",
    "machine": "",
}
iid = mod.write_row(mod.Path(db), row, [])
if not iid or calls["n"] != 2:
    sys.exit("retry failed: id=%r calls=%r" % (iid, calls["n"]))
con = sqlite3.connect(db)
n = con.execute("SELECT COUNT(*) FROM invocations").fetchone()[0]
con.close()
if n != 1:
    sys.exit("retry landed %d rows, want 1" % n)
print("retry row", iid)
EOF
then
  fail "retry" "case 10 retry driver failed"
else
  ok "retry-through-lock"
fi

# --- case 11: retry exhaustion keeps the terse one-line contract -------------
say "case 11: an exhausted retry fails quietly (one stderr line, no row)"
C9="$DBT/c9.db"
if ! "$PYTHON" - "$C9" "$TOOL" <<'EOF'
import contextlib, importlib.util, io, sys
from importlib import machinery

db, tool = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "skill_log_exhaust", tool, loader=machinery.SourceFileLoader("skill_log_exhaust", tool)
)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

# Shrink the budget so the case is fast; every attempt is busy.
mod.WRITE_BUDGET_SECONDS = 0.3
mod.WRITE_RETRY_SLEEP = 0.05


def always_busy(path, timeout=30):
    import sqlite3

    raise sqlite3.OperationalError("database is locked")


mod.write_conn = always_busy
ns = mod.argparse.Namespace(
    skill="exhaust", problem=[], parent="", t3_thread="", model="prov-a/m-x",
    opencode_thread="ses_stub", project="", worktree="", machine="", json=False,
    dry_run=False, db=mod.Path(db),
)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = mod.cmd_add(ns)
text = err.getvalue()
if rc != 1:
    sys.exit("exhausted retry rc=%r, want 1" % rc)
if "cannot write the log" not in text or "Traceback" in text:
    sys.exit("stderr contract broken: %r" % text[:200])
if mod.Path(db).exists():
    sys.exit("a failed write created the db file")
print("terse failure")
EOF
then
  fail "exhaust" "case 11 exhaustion driver failed"
else
  ok "exhaust-quiet"
fi

# --- case 12: resolve marks a row and the resolved count follows ----------
say "case 12: resolve marks a row and the resolved count follows"
C12="$DBT/c12.db"
env -u T3CODE_HOST -u T3CODE_PORT -u OPENCODE_SESSION_ID \
    "$TOOL" add --skill resolve-me --problem "p1" --db "$C12" >/dev/null
out="$(strip_env "$TOOL" resolve --id 1 --fix abc1234 --db "$C12" --json)"
assert_eq "resolve" "resolve --json echoes the fix" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["fix"])')" \
    "abc1234"
resolved="$(strip_env "$TOOL" stats --db "$C12" --json | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["resolved"])')"
assert_eq "resolve" "stats counts the resolved row" "$resolved" "1"
# The publisher's list: --unresolved drops a row once a fix resolved it.
C12U="$DBT/c12-unresolved.db"
strip_env "$TOOL" add --skill resolved-row --db "$C12U" >/dev/null
strip_env "$TOOL" add --skill open-row --problem "still open" --db "$C12U" >/dev/null
strip_env "$TOOL" resolve --id 1 --fix abc1234 --db "$C12U" >/dev/null
assert_eq "resolve" "the unresolved filter lists only open rows" \
    "$(strip_env "$TOOL" show --unresolved --db "$C12U" --json |
        "$PYTHON" -c 'import json,sys; print(",".join(json.loads(line)["skill"] for line in sys.stdin))')" \
    "open-row"
# Re-running is safe: same row, same fix.
strip_env "$TOOL" resolve --id 1 --fix abc1234 --db "$C12" >/dev/null
assert_eq "resolve" "re-running leaves the same resolved count" \
    "$(strip_env "$TOOL" stats --db "$C12" --json | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["resolved"])')" "1"
# A missing id is a named failure, not a traceback.
out="$(strip_env "$TOOL" resolve --id 99 --fix abc1234 --db "$C12" 2>&1 >/dev/null)"
case "$out" in
    "skill-log: no invocation 99 in "*) ok "missing-id-named" ;;
    *) fail "resolve" "missing id is not named: $out" ;;
esac
# A missing db is a named failure.
out="$(strip_env "$TOOL" resolve --id 1 --fix abc1234 --db "$DBT/nope.db" 2>&1 >/dev/null)"
case "$out" in
    "skill-log: no log db at "*"nope.db") ok "missing-db-named" ;;
    *) fail "resolve" "missing db is not named: $out" ;;
esac
# Dry-run writes nothing.
out="$(strip_env "$TOOL" resolve --id 1 --fix deadbeef --db "$C12" --dry-run --json)"
assert_eq "resolve" "dry-run previews the fix" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["fix"])')" \
    "deadbeef"
assert_eq "resolve" "dry-run leaves the row's fix" \
    "$(strip_env "$TOOL" show --db "$C12" --json | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["fix"])')" \
    "abc1234"

# --- case 13: sync merges a remote log without duplicating -------------------
say "case 13: sync merges a remote log, idempotent, takes the owner's fix forward"
LOCAL13="$DBT/c13.db"
REMOTE13="$DBT/c13-remote.db"
# q13 <db> <sql>: one scalar, used for the merge's provenance asserts.
q13() {
    "$PYTHON" -c 'import sqlite3,sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(sys.argv[2]).fetchone()
print("" if row is None or row[0] is None else row[0])' "$1" "$2"
}
# The remote db stands in for another host's log: its rows name that host in
# machine, and its ids are only unique inside it.
strip_env "$TOOL" add --skill local-a --db "$LOCAL13" >/dev/null
strip_env "$TOOL" add --skill local-b --problem "local friction" --db "$LOCAL13" >/dev/null
strip_env "$TOOL" add --skill remote-a --machine otherbox \
    --problem "remote friction" --db "$REMOTE13" >/dev/null
strip_env "$TOOL" add --skill remote-b --machine otherbox --db "$REMOTE13" >/dev/null

# The transport shim: ssh drops its options and the host, then runs the
# remote command here, so the real snapshot script and merge run end to end
# with a local file standing in for the VPS. Only the identity probe is
# answered with a fake remote name — the machine running the test is not the
# machine it stands in for.
mkdir -p "$S/transport"
cat > "$S/transport/ssh" <<'SHIM'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift
if [ "$3" = identity ]; then
    # Run the real identity probe, then stand in for the machine it reported.
    "$@" >/dev/null || exit 1
    printf 'skill-log-host %s\n' "${FAKE_REMOTE_HOST:-otherbox}"
    exit 0
fi
# ssh hands its arguments to the remote shell as one string; so does this.
exec /bin/sh -c "$*"
SHIM
chmod +x "$S/transport/ssh"
SYNC13() { strip_env env PATH="$S/transport:$PATH" "$@"; }

out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$LOCAL13" --json)"
assert_eq "sync" "first sync inserts the remote rows" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "2"
assert_eq "sync" "first sync reports no updates" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["updated"])')" \
    "0"
assert_eq "sync" "the aggregate holds both dbs' rows" "$(count_rows "$LOCAL13")" "4"
assert_eq "sync" "a merged row keeps its owner and its id there" \
    "$(q13 "$LOCAL13" "SELECT group_concat(machine || ':' || origin_id, ',') FROM invocations WHERE origin_id > 0 ORDER BY origin_id")" \
    "otherbox:1,otherbox:2"
assert_eq "sync" "a merged row's problems come along" \
    "$(q13 "$LOCAL13" "SELECT p.problem FROM problems p JOIN invocations i ON i.id = p.invocation_id WHERE i.skill = 'remote-a'")" \
    "remote friction"
assert_eq "sync" "local rows are not rewritten as copies" \
    "$(q13 "$LOCAL13" "SELECT COUNT(*) FROM invocations WHERE machine = '$("$PYTHON" -c 'import socket; print(socket.gethostname())')'")" \
    "2"

out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$LOCAL13" --json)"
assert_eq "sync" "re-running merges nothing new" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "0"
assert_eq "sync" "re-running reports the rows unchanged" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["unchanged"])')" \
    "2"
assert_eq "sync" "re-running leaves the row count alone" "$(count_rows "$LOCAL13")" "4"

# A row resolved on the owner is resolved in the aggregate after the next
# merge — the post-commit step flows in even though it ran on another host.
strip_env "$TOOL" resolve --id 1 --fix abc1234 --db "$REMOTE13" >/dev/null
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$LOCAL13" --json)"
assert_eq "sync" "the owner's fix arrives as an update" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["updated"])')" \
    "1"
assert_eq "sync" "the merged copy carries the fix" \
    "$(q13 "$LOCAL13" "SELECT fix FROM invocations WHERE machine = 'otherbox' AND origin_id = 1")" \
    "abc1234"
assert_eq "sync" "stats counts the merged row as resolved" \
    "$(strip_env "$TOOL" stats --db "$LOCAL13" --json | "$PYTHON" -c 'import json,sys; print(sum(json.loads(line)["resolved"] for line in sys.stdin))')" \
    "1"
assert_eq "sync" "a local row's fix is untouched by the merge" \
    "$(q13 "$LOCAL13" "SELECT fix FROM invocations WHERE skill = 'local-a'")" ""

# --machine reads one host's slice out of the aggregate.
assert_eq "sync" "show --machine reads the merged host's rows" \
    "$(strip_env "$TOOL" show --machine otherbox --db "$LOCAL13" --json | wc -l)" "2"

# --dry-run reports the same counts and writes nothing: no file, no rows.
DRY13="$DBT/c13-dry.db"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$DRY13" --dry-run --json)"
assert_eq "sync" "dry-run reports what it would insert" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "2"
if [ -e "$DRY13" ]; then
    fail "sync" "a dry run created the aggregate db"
else
    ok "sync-dry-run-writes-nothing"
fi

# Over an existing aggregate the dry run merges into a copy of it (copy_db):
# the predicted counts must match the real merge and the real db must not move.
strip_env "$TOOL" resolve --id 2 --fix beef123 --db "$REMOTE13" >/dev/null
before_rows="$(count_rows "$LOCAL13")"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$LOCAL13" --dry-run --json)"
assert_eq "sync" "dry-run over an existing db predicts the pending update" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["updated"], d["inserted"])')" \
    "1 0"
assert_eq "sync" "dry-run leaves the existing aggregate unchanged" \
    "$(count_rows "$LOCAL13")/$(q13 "$LOCAL13" "SELECT fix FROM invocations WHERE machine = 'otherbox' AND origin_id = 2")" \
    "$before_rows/"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE13" --db "$LOCAL13" --json)"
assert_eq "sync" "the real merge lands what the dry run predicted" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["updated"], d["inserted"])')" \
    "1 0"
assert_eq "sync" "the second owner's fix is in the aggregate" \
    "$(q13 "$LOCAL13" "SELECT fix FROM invocations WHERE machine = 'otherbox' AND origin_id = 2")" \
    "beef123"

# A remote that is unreachable, or has no log, is one named line and exit 1.
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$DBT/nope.db" --db "$LOCAL13" 2>&1 >/dev/null)"
st="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$DBT/nope.db" --db "$LOCAL13" >/dev/null 2>&1; echo $?)"
case "$out" in
    "skill-log: cannot read otherbox's log:"*)
        assert_eq "sync" "a missing remote log exits 1" "$st" "1" ;;
    *) fail "sync" "a missing remote log is not named: $out" ;;
esac
# Syncing this machine into itself would insert duplicate copies of its own
# rows. The guard keys on the name the remote reports, not the ssh alias, so
# it fires even when the alias is reassuring.
SELF="$(hostname)"
out="$(SYNC13 FAKE_REMOTE_HOST="$SELF" "$TOOL" sync --from localhost --remote-db "$REMOTE13" --db "$LOCAL13" 2>&1 >/dev/null)"
st="$(SYNC13 FAKE_REMOTE_HOST="$SELF" "$TOOL" sync --from localhost --remote-db "$REMOTE13" --db "$LOCAL13" >/dev/null 2>&1; echo $?)"
case "$out" in
    "skill-log: localhost is this machine ($SELF);"*)
        assert_eq "sync" "self-sync is refused through an alias" "$st" "1" ;;
    *) fail "sync" "self-sync is not refused: $out" ;;
esac
assert_eq "sync" "the refused self-sync inserted nothing" "$(count_rows "$LOCAL13")" "4"

# A remote still on the old schema (no model/parent/fix/resolved_at/origin_id)
# merges, with blanks for the columns it predates and its blank machine
# filled from the host it came from.
OLD13="$DBT/c13-old.db"
mkv1db "$OLD13" old-remote-skill
out="$(SYNC13 FAKE_REMOTE_HOST=oldbox "$TOOL" sync --from oldbox --remote-db "$OLD13" --db "$LOCAL13" --json)"
assert_eq "sync" "an old-schema remote merges" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "1"
assert_eq "sync" "its blank machine lands under the host it came from" \
    "$(q13 "$LOCAL13" "SELECT machine || ' ' || skill || ' model=[' || model || ']' FROM invocations WHERE origin_id = 1 AND machine = 'oldbox'")" \
    "oldbox old-remote-skill model=[]"
out="$(SYNC13 FAKE_REMOTE_HOST=oldbox "$TOOL" sync --from oldbox --remote-db "$OLD13" --db "$LOCAL13" --json)"
assert_eq "sync" "the filled-in owner keys the re-run too" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["inserted"], d["unchanged"])')" \
    "0 1"

# --- case 14: the pull reads a live WAL and never changes the remote --------
say "case 14: a live writer's uncheckpointed row arrives; the remote is untouched"
REMOTE14="$DBT/c14-remote.db"
LOCAL14="$DBT/c14-local.db"
strip_env "$TOOL" add --skill wal-committed --machine otherbox --db "$REMOTE14" >/dev/null
digest14() {
    "$PYTHON" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}
# A second writer holds the db open with a committed, uncheckpointed row: the
# row lives only in the -wal file, which is exactly what a naive file copy
# would miss.
"$PYTHON" - "$REMOTE14" "$S/wal-live" <<'EOF' &
import sqlite3, sys, time
from pathlib import Path

con = sqlite3.connect(sys.argv[1])
con.execute(
    "INSERT INTO invocations (ts, skill, machine)"
    " VALUES ('2026-11-10T00:00:00+00:00', 'wal-live-skill', 'otherbox')"
)
con.commit()
Path(sys.argv[2]).write_text("ready")
time.sleep(60)
EOF
WALPID=$!
n=0
while [ ! -f "$S/wal-live" ] && [ "$n" -lt 100 ]; do
    sleep 0.1
    n=$((n + 1))
done
before="$(digest14 "$REMOTE14")"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$REMOTE14" --db "$LOCAL14" --json)"
after="$(digest14 "$REMOTE14")"
kill "$WALPID" 2>/dev/null
wait "$WALPID" 2>/dev/null
assert_eq "sync-wal" "the live row and the committed row both arrive" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "2"
assert_eq "sync-wal" "the uncheckpointed row is in the aggregate" \
    "$(q13 "$LOCAL14" "SELECT COUNT(*) FROM invocations WHERE skill = 'wal-live-skill'")" "1"
assert_eq "sync-wal" "the remote db file is byte-identical afterwards" "$after" "$before"

# --- case 15: chained merges stay idempotent, and the guards hold -----------
say "case 15: chained merges stay idempotent; bad input is named"
HOSTA="$DBT/c15-a.db"
AGG="$DBT/c15-b.db"
C15="$DBT/c15-c.db"
strip_env "$TOOL" add --skill a-one --machine hosta --problem "a-friction" --db "$HOSTA" >/dev/null
strip_env "$TOOL" add --skill a-two --machine hosta --db "$HOSTA" >/dev/null
SYNC13 FAKE_REMOTE_HOST=hosta "$TOOL" sync --from hosta --remote-db "$HOSTA" --db "$AGG" >/dev/null
strip_env "$TOOL" add --skill b-own --machine bhost --problem "b-friction" --db "$AGG" >/dev/null
# The middle db is itself an aggregate; the owner ids travel with the rows,
# so pulling it and then pulling the owner again never duplicates a row.
SYNC13 FAKE_REMOTE_HOST=bhost "$TOOL" sync --from agg --remote-db "$AGG" --db "$C15" >/dev/null
assert_eq "sync-chain" "the chained aggregate holds three rows" "$(count_rows "$C15")" "3"
assert_eq "sync-chain" "a chained copy keeps the true owner and id" \
    "$(q13 "$C15" "SELECT group_concat(machine || ':' || origin_id, ',') FROM invocations WHERE origin_id > 0 ORDER BY origin_id")" \
    "bhost:3,hosta:1,hosta:2"
# Problems belong to the row that recorded them: a chained copy that carried
# the owner's id used to attach the middle db's problems to the wrong rows
# (and inflate the friction count).
assert_eq "sync-chain" "chained problems stay with their own invocation" \
    "$(q13 "$C15" "SELECT group_concat(x, ',') FROM (SELECT i.skill || '=' || COALESCE(p.problem, '-') AS x FROM invocations i LEFT JOIN problems p ON p.invocation_id = i.id ORDER BY i.skill)")" \
    "a-one=a-friction,a-two=-,b-own=b-friction"
assert_eq "sync-chain" "the friction count is not inflated by the chain" \
    "$(q13 "$C15" "SELECT SUM(n) FROM (SELECT COUNT(p.ordinal) AS n FROM invocations i LEFT JOIN problems p ON p.invocation_id = i.id GROUP BY i.id)")" \
    "2"
out="$(SYNC13 FAKE_REMOTE_HOST=hosta "$TOOL" sync --from hosta --remote-db "$HOSTA" --db "$C15" --json)"
assert_eq "sync-chain" "pulling the owner after the aggregate adds nothing" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["inserted"], d["unchanged"])')" \
    "0 2"
assert_eq "sync-chain" "the chain left no duplicates" "$(count_rows "$C15")" "3"

# A file that is not a skill-log db, and a file that is not sqlite at all,
# are each one named line — never a remote traceback.
FOREIGN="$DBT/c15-foreign.db"
"$PYTHON" -c 'import sqlite3,sys; con = sqlite3.connect(sys.argv[1]); con.execute("CREATE TABLE invocations (note TEXT)"); con.commit()' "$FOREIGN"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$FOREIGN" --db "$C15" 2>&1 >/dev/null)"
st="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$FOREIGN" --db "$C15" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"not a skill-log database"*)
        assert_eq "sync-guard" "a foreign invocations table is refused" "$st" "1" ;;
    *) fail "sync-guard" "a foreign table is not refused: $out" ;;
esac
CORRUPT15="$DBT/c15-corrupt.db"
printf 'not a sqlite file at all' > "$CORRUPT15"
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$CORRUPT15" --db "$C15" 2>&1 >/dev/null)"
st="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$CORRUPT15" --db "$C15" >/dev/null 2>&1; echo $?)"
case "$out" in
    *Traceback* | "")
        fail "sync-guard" "a corrupt remote is not named: $out" ;;
    *"cannot read otherbox's log:"*)
        assert_eq "sync-guard" "a corrupt remote is named, exit 1" "$st" "1" ;;
    *) fail "sync-guard" "a corrupt remote says something else: $out" ;;
esac
# A host that looks like an ssh option never reaches ssh as one.
out="$(SYNC13 "$TOOL" sync --from '-oProxyCommand=echo pwned' --db "$C15" 2>&1 >/dev/null)"
st="$(SYNC13 "$TOOL" sync --from '-oProxyCommand=echo pwned' --db "$C15" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"--from needs a host name"*)
        assert_eq "sync-guard" "an option-shaped host is refused" "$st" "2" ;;
    *) fail "sync-guard" "an option-shaped host is not refused: $out" ;;
esac
# A blank --fix would report a resolution that stats never counts.
C15F="$DBT/c15-fix.db"
strip_env "$TOOL" add --skill fixme --db "$C15F" >/dev/null
out="$(strip_env "$TOOL" resolve --id 1 --fix '  ' --db "$C15F" 2>&1 >/dev/null)"
st="$(strip_env "$TOOL" resolve --id 1 --fix '  ' --db "$C15F" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"--fix needs a commit hash"*)
        assert_eq "resolve-guard" "a blank --fix is refused" "$st" "2" ;;
    *) fail "resolve-guard" "a blank --fix is not refused: $out" ;;
esac
assert_eq "resolve-guard" "the refused --fix left the row unresolved" \
    "$(q13 "$C15F" "SELECT fix || resolved_at FROM invocations WHERE id = 1")" ""

# A remote whose problems table is unreadable must not merge its rows
# without their friction and call that success.
BADPROB="$DBT/c15-badproblems.db"
"$PYTHON" - "$BADPROB" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    CREATE TABLE invocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        skill TEXT NOT NULL
    );
    CREATE TABLE problems (note TEXT);
    INSERT INTO invocations (ts, skill)
        VALUES ('2026-01-01T00:00:00+00:00', 'shape');
"""
)
con.commit()
con.close()
EOF
out="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$BADPROB" --db "$C15" 2>&1 >/dev/null)"
st="$(SYNC13 "$TOOL" sync --from otherbox --remote-db "$BADPROB" --db "$C15" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"problems table is unreadable"*)
        assert_eq "sync-problems" "an unreadable problems table is named" "$st" "1" ;;
    *) fail "sync-problems" "a problems failure is not named: $out" ;;
esac
assert_eq "sync-problems" "nothing merged from that snapshot" "$(count_rows "$C15")" "3"

# Resolving a merged copy is a promise the next sync erases: refuse it and
# name the owner. C15 id 1 is hosta's copy of a-one.
out="$(strip_env "$TOOL" resolve --id 1 --fix cafebabe --db "$C15" 2>&1 >/dev/null)"
st="$(strip_env "$TOOL" resolve --id 1 --fix cafebabe --db "$C15" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"belongs to hosta"*)
        assert_eq "resolve-owner" "resolve refuses a merged copy" "$st" "1" ;;
    *) fail "resolve-owner" "a merged copy is not refused: $out" ;;
esac
assert_eq "resolve-owner" "the refused resolve left the copy untouched" \
    "$(q13 "$C15" "SELECT fix FROM invocations WHERE id = 1")" ""

# A third-party aggregate that mirrors this machine: its copies of this
# host's rows are skipped, so a reverse pull cannot duplicate them.
SELF_HOST="$(hostname)"
MIRROR="$DBT/c15-mirror.db"
MIRROR_AGG="$DBT/c15-mirror-agg.db"
strip_env "$TOOL" add --skill mine --machine "$SELF_HOST" --db "$MIRROR" >/dev/null
# A third-party aggregate stores this machine's rows as copies (origin_id 1);
# this db cannot hold that shape itself, so the fixture is built directly.
cp "$MIRROR" "$MIRROR_AGG"
"$PYTHON" - "$MIRROR_AGG" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE invocations SET origin_id = 1 WHERE id = 1")
con.commit()
con.close()
EOF
out="$(SYNC13 FAKE_REMOTE_HOST=mirage "$TOOL" sync --from mirage --remote-db "$MIRROR_AGG" --db "$MIRROR" --json)"
assert_eq "sync-own-rows" "this machine's mirrored rows are skipped" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["inserted"], d["skipped"])')" \
    "0 1"
assert_eq "sync-own-rows" "the mirror gained no duplicate" "$(count_rows "$MIRROR")" "1"

# A rebuilt owner reuses its ids: the stale copy is replaced, not patched,
# and the new run's friction comes with it.
REBUILD="$DBT/c15-rebuild.db"
strip_env "$TOOL" add --skill first-run --machine rebuildbox --db "$REBUILD" >/dev/null
SYNC13 FAKE_REMOTE_HOST=rebuildbox "$TOOL" sync --from rebuildbox --remote-db "$REBUILD" --db "$C15" >/dev/null
rm -f "$REBUILD"
strip_env "$TOOL" add --skill second-run --machine rebuildbox --problem "fresh friction" --db "$REBUILD" >/dev/null
out="$(SYNC13 FAKE_REMOTE_HOST=rebuildbox "$TOOL" sync --from rebuildbox --remote-db "$REBUILD" --db "$C15" --json)"
assert_eq "sync-rebuild" "a rebuilt owner replaces its stale copy" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["replaced"], d["inserted"], d["unchanged"])')" \
    "1 1 0"
assert_eq "sync-rebuild" "the aggregate carries the new run, not the stale one" \
    "$(q13 "$C15" "SELECT skill FROM invocations WHERE machine = 'rebuildbox'")" "second-run"
assert_eq "sync-rebuild" "the new run's problem arrived" \
    "$(q13 "$C15" "SELECT p.problem FROM problems p JOIN invocations i ON i.id = p.invocation_id WHERE i.skill = 'second-run'")" \
    "fresh friction"

# --- case 16: read paths name a damaged log, and never empty it -------------
say "case 16: a damaged log is named; a problems-less log still counts"
MALFORMED="$DBT/c16-malformed.db"
strip_env "$TOOL" add --skill trunc --db "$MALFORMED" >/dev/null
"$PYTHON" - "$MALFORMED" <<'EOF'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes()[:1024])  # a valid header, a truncated page
EOF
out="$(strip_env "$TOOL" stats --db "$MALFORMED" 2>&1 >/dev/null)"
st="$(strip_env "$TOOL" stats --db "$MALFORMED" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"is not a skill-log database"*)
        assert_eq "stats-corrupt" "a malformed log is named, not read as empty" "$st" "1" ;;
    *) fail "stats-corrupt" "a malformed log is not named: $out" ;;
esac
out="$(strip_env "$TOOL" stats --db "$MALFORMED" --by-model 2>&1 >/dev/null)"
case "$out" in
    *Traceback*) fail "stats-corrupt" "malformed --by-model tracebacks: $out" ;;
    *"is not a skill-log database"*) ok "stats-corrupt-by-model" ;;
    *) fail "stats-corrupt" "malformed --by-model says something else: $out" ;;
esac

# A log written before the problems table existed still has invocation rows.
NOPROB="$DBT/c16-noproblems.db"
"$PYTHON" - "$NOPROB" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    CREATE TABLE invocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        skill TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT '',
        project TEXT NOT NULL DEFAULT '',
        t3_thread TEXT NOT NULL DEFAULT '',
        opencode_thread TEXT NOT NULL DEFAULT '',
        worktree TEXT NOT NULL DEFAULT '',
        machine TEXT NOT NULL DEFAULT '',
        fix TEXT NOT NULL DEFAULT '',
        resolved_at TEXT NOT NULL DEFAULT ''
    );
    INSERT INTO invocations (ts, skill)
        VALUES ('2026-01-01T00:00:00+00:00', 'no-problems');
"""
)
con.commit()
con.close()
EOF
out="$(strip_env "$TOOL" stats --db "$NOPROB")"
case "$out" in
    "skill "*)
        assert_eq "stats-noproblems" "a problems-less log counts its rows" \
            "$(printf '%s' "$out" | tail -1 | tr -s ' ')" "no-problems 1 0 0 0 0" ;;
    *) fail "stats-noproblems" "a problems-less log read as empty: $out" ;;
esac
# show is the read path a user runs first; it names damage too, and a log
# with rows but no problems table still renders its rows.
out="$(strip_env "$TOOL" show --db "$MALFORMED" 2>&1 >/dev/null)"
st="$(strip_env "$TOOL" show --db "$MALFORMED" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"is not a skill-log database"*)
        assert_eq "show-corrupt" "show names a damaged log" "$st" "1" ;;
    *) fail "show-corrupt" "show does not name damage: $out" ;;
esac
out="$(strip_env "$TOOL" show --db "$NOPROB")"
case "$out" in
    *no-problems*) ok "show-noproblems-rows" ;;
    *) fail "show-corrupt" "show dropped a problems-less log's rows: $out" ;;
esac

# show orders by when a run happened, not by when a sync landed it.
ORD="$DBT/c16-order.db"
"$PYTHON" - "$ORD" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    CREATE TABLE invocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        skill TEXT NOT NULL,
        project TEXT NOT NULL DEFAULT '',
        t3_thread TEXT NOT NULL DEFAULT '',
        opencode_thread TEXT NOT NULL DEFAULT '',
        worktree TEXT NOT NULL DEFAULT '',
        machine TEXT NOT NULL DEFAULT '',
        fix TEXT NOT NULL DEFAULT '',
        resolved_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE problems (
        invocation_id INTEGER NOT NULL,
        ordinal INTEGER NOT NULL,
        problem TEXT NOT NULL,
        PRIMARY KEY (invocation_id, ordinal)
    );
    INSERT INTO invocations (ts, skill, machine)
        VALUES ('2020-01-01T00:00:00+00:00', 'ancient', 'oldbox');
    INSERT INTO invocations (ts, skill, machine)
        VALUES ('2026-11-10T12:00:00-03:00', 'fresh', 'thisbox');
"""
)
con.commit()
con.close()
EOF
assert_eq "show-order" "show orders by invocation time, not merge order" \
    "$(strip_env "$TOOL" show --db "$ORD" --last 1 --json | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["skill"])')" \
    "fresh"

# --- case 17: the default remote path needs no flag -------------------------
say "case 17: sync uses the remote's default log path when --remote-db is absent"
DEFAULT_REMOTE="$HOME/.local/state/skill-log/skills.db"
DEFAULT_LOCAL="$DBT/c17-local.db"
strip_env "$TOOL" add --skill default-path --machine otherbox --db "$DEFAULT_REMOTE" >/dev/null
out="$(SYNC13 "$TOOL" sync --from otherbox --db "$DEFAULT_LOCAL" --json)"
assert_eq "sync-default-db" "the default remote path is used" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "1"
assert_eq "sync-default-db" "the default-path row arrives" \
    "$(q13 "$DEFAULT_LOCAL" "SELECT skill FROM invocations WHERE origin_id = 1")" "default-path"
# A remote that keeps its state elsewhere: its default follows its own
# XDG_STATE_HOME, not this machine's.
XDG_DIR="$S/xdgstate"
XOUT="$DBT/c17-xdg.db"
strip_env "$TOOL" add --skill xdg-default --machine otherbox \
    --db "$XDG_DIR/skill-log/skills.db" >/dev/null
out="$(SYNC13 XDG_STATE_HOME="$XDG_DIR" "$TOOL" sync --from otherbox --db "$XOUT" --json)"
assert_eq "sync-xdg" "the remote default follows its XDG_STATE_HOME" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["inserted"])')" \
    "1"

# --- case 18: a concurrent merge's unique-index collision is retried ------
say "case 18: a parallel merge's index collision retries and converges"
C18="$DBT/c18.db"
if ! "$PYTHON" - "$C18" "$TOOL" <<'EOF'
import importlib.util, sqlite3, sys, uuid
from importlib import machinery
from pathlib import Path

db, tool = sys.argv[1], sys.argv[2]
name = "skill_log_collide_" + uuid.uuid4().hex
spec = importlib.util.spec_from_file_location(
    name, tool, loader=machinery.SourceFileLoader(name, tool)
)
mod = importlib.util.module_from_spec(spec)
sys.modules[name] = mod
spec.loader.exec_module(mod)

row = {
    "id": 1,
    "ts": "2026-01-01T00:00:00+00:00",
    "skill": "collide",
    "parent": "",
    "model": "",
    "project": "",
    "t3_thread": "",
    "opencode_thread": "",
    "worktree": "",
    "machine": "otherbox",
    "fix": "",
    "resolved_at": "",
    "origin_id": 0,
}

real_insert = mod.insert_invocation
real_conn = mod.write_conn
state = {"n": 0, "attempts": 0}


def counting_conn(path, timeout=30):
    state["attempts"] += 1
    return real_conn(path, timeout=timeout)


def racing(conn, record, origin, problems):
    """A parallel merge lands the same (machine, origin_id) between this
    attempt's "known" read and its insert. The insert then hits the unique
    index for real — the collision the retry loop exists for — and the retry
    must re-read, find the row, and converge instead of failing."""
    state["n"] += 1
    if state["n"] == 1:
        other = sqlite3.connect(db)
        other.execute(
            "INSERT INTO invocations (ts, skill, machine, origin_id)"
            " VALUES (?, ?, ?, ?)",
            (record["ts"], record["skill"], record["machine"], origin),
        )
        other.commit()
        other.close()
    real_insert(conn, record, origin, problems)


mod.insert_invocation = racing
mod.write_conn = counting_conn
counts = mod.merge_snapshot(Path(db), [row], {}, "otherbox")
con = sqlite3.connect(db)
rows = con.execute("SELECT COUNT(*), MAX(origin_id) FROM invocations").fetchone()
con.close()
if (
    state["n"] != 1
    or state["attempts"] != 2
    or (counts.inserted, counts.unchanged) != (0, 1)
    or rows != (1, 1)
):
    sys.exit(
        "collision did not converge: race=%r conns=%r counts=%r rows=%r"
        % (state["n"], state["attempts"], counts, rows)
    )
print("retry converged", counts.unchanged)
EOF
then
    fail "retry-merge" "collision retry driver failed"
else
    ok "retry-merge-collision"
fi

# --- case 19: resolve-merged stamps the rows a merged fix commit names -----
say "case 19: resolve-merged stamps the rows a merged fix commit names"
R19="$S/c19-repo"
H19="$(hostname)"
DB19="$DBT/c19.db"
mkdir -p "$R19"
g19() { git -C "$R19" "$@"; }
g19 init -q
g19 config user.email test@example.com
g19 config user.name test
g19 config commit.gpgsign false
# commit19 <subject> <trailer-line>: one commit whose last paragraph is the
# marker block, the shape a squash-merged PR body leaves behind.
commit19() {
    printf '%s\n' "$1" > "$R19/file"
    g19 add file
    g19 commit -q -m "$1" -m "Body paragraph." -m "$2"
}

strip_env "$TOOL" add --skill first-fix --db "$DB19" >/dev/null
strip_env "$TOOL" add --skill second-fix --db "$DB19" >/dev/null
commit19 "skills: fix two things" "Skill-log-Fix: $H19#1, $H19#2"
FIRST="$(g19 rev-parse --short=9 HEAD)"
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --db "$DB19" --json 2>/dev/null)"
assert_eq "resolve-merged" "both named rows are stamped" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(sorted(json.loads(sys.stdin.read())["resolved"])))')" \
    "$H19#1,$H19#2"
assert_eq "resolve-merged" "the stamp is the fix commit" \
    "$(q13 "$DB19" "SELECT group_concat(substr(fix, 1, 9), ',') FROM invocations ORDER BY id")" \
    "$FIRST,$FIRST"
assert_eq "resolve-merged" "stats counts both as resolved" \
    "$(strip_env "$TOOL" stats --db "$DB19" --json | "$PYTHON" -c 'import json,sys; print(sum(json.loads(line)["resolved"] for line in sys.stdin))')" \
    "2"
# Idempotent: the hook fires on every pull.
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --db "$DB19" --json 2>/dev/null)"
assert_eq "resolve-merged" "re-running stamps nothing and changes nothing" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(len(d["resolved"]), ",".join(sorted(d["unchanged"])))')" \
    "0 $H19#1,$H19#2"

# A row logged after the commit is an id reused by a rebuilt log, not the
# row the commit fixed: skipped, with the reason named.
commit19 "skills: name a row that does not exist yet" "Skill-log-Fix: $H19#3"
sleep 1
strip_env "$TOOL" add --skill logged-later --db "$DB19" >/dev/null
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --db "$DB19" 2>&1 >/dev/null)"
case "$out" in
    *"$H19#3 skipped: logged after that commit"*) ok "resolve-merged-later-row" ;;
    *) fail "resolve-merged" "a later row is not guarded: $out" ;;
esac
assert_eq "resolve-merged" "the guarded row stays unresolved" \
    "$(q13 "$DB19" "SELECT fix FROM invocations WHERE id = 3")" ""

# An id this db does not have, a merged copy, and a documented placeholder.
commit19 "skills: name things that are not ours" "Skill-log-Fix: $H19#99, $H19#4, otherbox#4, <id>, 7"
"$PYTHON" - "$DB19" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.execute(
    "INSERT INTO invocations (ts, skill, machine, origin_id)"
    " VALUES ('2026-01-01T00:00:00+00:00', 'copy', 'otherbox', 4)"
)
con.commit()
con.close()
EOF
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --db "$DB19" 2>&1 >/dev/null)"
case "$out" in
    *"$H19#99 skipped: not in this db"*) ok "resolve-merged-unknown-id" ;;
    *) fail "resolve-merged" "an unknown id is not named: $out" ;;
esac
case "$out" in
    *"otherbox#4 skipped: merged copy owned by otherbox"*) ok "resolve-merged-copy" ;;
    *) fail "resolve-merged" "a merged copy is not refused: $out" ;;
esac
# show --json hands the publisher the marker verbatim, including a synced
# copy's owner id (its own id in this db is not the marker).
assert_eq "resolve-merged" "show --json renders the marker a marker uses" \
    "$(strip_env "$TOOL" show --machine otherbox --db "$DB19" --json |
        "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["marker"])')" \
    "otherbox#4"
case "$out" in
    *"not a Skill-log-Fix marker (machine#id): <id>"*) ok "resolve-merged-placeholder" ;;
    *) fail "resolve-merged" "a placeholder is not reported: $out" ;;
esac
case "$out" in
    *"not a Skill-log-Fix marker (machine#id): 7"*) ok "resolve-merged-bare-id-refused" ;;
    *) fail "resolve-merged" "a bare id is not refused: $out" ;;
esac

# --since narrows the scan, and --dry-run writes nothing.
DB19S="$DBT/c19-since.db"
strip_env "$TOOL" add --skill since-old --db "$DB19S" >/dev/null
commit19 "skills: name the old row" "Skill-log-Fix: $H19#1"
BASE="$(g19 rev-parse HEAD)"
strip_env "$TOOL" add --skill since-new --db "$DB19S" >/dev/null
commit19 "skills: name a newer row" "Skill-log-Fix: $H19#2"
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --since "$BASE" --db "$DB19S" --json 2>/dev/null)"
assert_eq "resolve-merged" "--since only acts on what came after it" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["resolved"]))')" \
    "$H19#2"
assert_eq "resolve-merged" "the marker before --since left its row alone" \
    "$(q13 "$DB19S" "SELECT fix FROM invocations WHERE id = 1")" ""
DB19D="$DBT/c19-dry.db"
strip_env "$TOOL" add --skill dry-run --db "$DB19D" >/dev/null
commit19 "skills: name the dry-run row" "Skill-log-Fix: $H19#1"
out="$(cd "$R19" && strip_env "$TOOL" resolve-merged --db "$DB19D" --dry-run --json)"
assert_eq "resolve-merged" "dry-run reports the row it would stamp" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["resolved"]))')" \
    "$H19#1"
assert_eq "resolve-merged" "dry-run leaves the row unresolved" \
    "$(q13 "$DB19D" "SELECT fix FROM invocations WHERE id = 1")" ""

# The reliable trigger: the installer writes a post-merge hook, and a pull
# that lands the marked commit stamps the row with no one running anything.
mkdir -p "$HOME/bin"
ln -sf "$TOOL" "$HOME/bin/skill-log"
HOOK_ID="$(strip_env "$TOOL" add --skill hook-resolved --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
g19 checkout -q -b hook-branch
commit19 "skills: fix the hook row" "Skill-log-Fix: $H19#$HOOK_ID"
HOOK_COMMIT="$(g19 rev-parse HEAD)"
g19 checkout -q -
if ! (cd "$R19" && sed -n '/^# post-merge: stamp/,$p' "$WORK/scripts/setup-git.sh" | bash) >/dev/null 2>&1; then
    fail "resolve-merged-hook" "the hook installer failed"
elif ! env -u XDG_STATE_HOME git -C "$R19" merge -q --ff-only hook-branch >/dev/null 2>&1; then
    fail "resolve-merged-hook" "the fast-forward merge with the hook installed failed"
else
    assert_eq "resolve-merged-hook" "a merge stamps the row its commit names" \
        "$(q13 "$HOME/.local/state/skill-log/skills.db" "SELECT fix FROM invocations WHERE id = $HOOK_ID")" \
        "$HOOK_COMMIT"
fi

# --- case 20: one machine, one identity, however its name is spelled -------
say "case 20: a renamed host keeps one identity for the merge and the marker"
C20="$DBT/c20.db"
if ! out20="$("$PYTHON" - "$C20" "$TOOL" <<'EOF'
import importlib.util, sqlite3, sys, uuid
from importlib import machinery
from pathlib import Path

db, tool = sys.argv[1], sys.argv[2]
name = "skill_log_alias_" + uuid.uuid4().hex
spec = importlib.util.spec_from_file_location(
    name, tool, loader=machinery.SourceFileLoader(name, tool)
)
mod = importlib.util.module_from_spec(spec)
sys.modules[name] = mod
spec.loader.exec_module(mod)


def row(machine, ident, skill):
    return {
        "id": ident,
        "ts": "2026-01-01T00:00:00+00:00",
        "skill": skill,
        "parent": "",
        "model": "",
        "project": "",
        "t3_thread": "",
        "opencode_thread": "",
        "worktree": "",
        "machine": machine,
        "fix": "",
        "resolved_at": "",
        "origin_id": 0,
    }


mod.merge_snapshot(Path(db), [row("box", 1, "boxed")], {}, "box")
# Same row, same host, renamed to its FQDN: one identity, so an update.
renamed = mod.merge_snapshot(
    Path(db), [row("box.example.com", 1, "boxed")], {}, "box.example.com"
)
mod.merge_snapshot(Path(db), [row("build.local", 1, "local")], {}, "build.local")
mod.merge_snapshot(Path(db), [row("build.prod", 1, "prod")], {}, "build.prod")
con = sqlite3.connect(db)
count, machine = con.execute(
    "SELECT COUNT(*), MIN(machine) FROM invocations WHERE origin_id = 1 AND skill = 'boxed'"
).fetchone()
built = con.execute(
    "SELECT COUNT(*) FROM invocations WHERE machine LIKE 'build.%'"
).fetchone()[0]
con.close()
print("alias", renamed.inserted, renamed.unchanged, count, machine)
print("distinct", built)
EOF
)"; then
    fail "host-alias" "the alias driver failed"
else
    assert_eq "host-alias" "a renamed host updates its row instead of inserting a second" \
        "$(printf '%s\n' "$out20" | sed -n '1p')" "alias 0 1 1 box"
    assert_eq "host-alias" "two hosts sharing a first label stay two machines" \
        "$(printf '%s\n' "$out20" | sed -n '2p')" "distinct 2"
fi

# The marker side of the same identity: a marker may spell the host the other
# way and still name the row. On the aggregate that turns a bare "not in this
# db" into "owned by <host>" — the report names who can resolve it.
R20="$S/c20-repo"
mkdir -p "$R20"
g20() { git -C "$R20" "$@"; }
g20 init -q
g20 config user.email test@example.com
g20 config user.name test
g20 config commit.gpgsign false
printf x > "$R20/f"
g20 add f
g20 commit -q -m "skills: fix the box row" -m "Skill-log-Fix: box.example.com#1"
C20L="$DBT/c20-local.db"
strip_env "$TOOL" add --skill boxed --machine box --db "$C20L" >/dev/null
out="$(cd "$R20" && strip_env "$TOOL" resolve-merged --db "$C20L" --json)"
assert_eq "host-alias" "a marker spelled as the FQDN resolves the stored short name" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["resolved"]))')" \
    "box.example.com#1"
assert_eq "host-alias" "the stored spelling is what got stamped" \
    "$(q13 "$C20L" "SELECT fix <> '' AND machine = 'box' FROM invocations WHERE id = 1")" "1"
out="$(cd "$R20" && strip_env "$TOOL" resolve-merged --db "$C20" 2>&1 >/dev/null)"
case "$out" in
    *"box.example.com#1 skipped: merged copy owned by box"*) ok "host-alias-copy-owner" ;;
    *) fail "host-alias" "a differently spelled marker on a copy is not named: $out" ;;
esac

# --- case 21: a marker the last-trailer-block rule hides is reported -------
say "case 21: a marker hidden by a later trailer block is reported, not dropped"
R21="$S/c21-repo"
mkdir -p "$R21"
g21() { git -C "$R21" "$@"; }
g21 init -q
g21 config user.email test@example.com
g21 config user.name test
g21 config commit.gpgsign false
DB21="$DBT/c21.db"
H21="$(hostname)"
strip_env "$TOOL" add --skill hidden-marker --db "$DB21" >/dev/null
printf y > "$R21/f"
g21 add f
# The shape a multi-author squash leaves behind: the marker block, then a
# trailer block GitHub appends after the body.
g21 commit -q -m "skills: fix one thing" -m "Skill-log-Fix: $H21#1" -m "Co-authored-by: someone <s@example.com>"
out="$(cd "$R21" && strip_env "$TOOL" resolve-merged --db "$DB21" 2>&1 >/dev/null)"
case "$out" in
    *"ignored marker"*"not in the commit's last trailer block"*)
        ok "resolve-merged-hidden-marker" ;;
    *) fail "resolve-merged" "a hidden marker is not reported: $out" ;;
esac
assert_eq "resolve-merged" "the hidden marker stamped nothing" \
    "$(q13 "$DB21" "SELECT fix FROM invocations WHERE id = 1")" ""
assert_eq "resolve-merged" "the JSON names the ignored marker" \
    "$(cd "$R21" && strip_env "$TOOL" resolve-merged --db "$DB21" --json |
        "$PYTHON" -c 'import json,sys; print(len(json.loads(sys.stdin.read())["ignored"]))')" "1"
assert_eq "resolve-merged" "--quiet prints nothing for a hidden marker" \
    "$(cd "$R21" && strip_env "$TOOL" resolve-merged --db "$DB21" --quiet 2>&1)" ""

# --- case 22: marker rules — newest wins, an option-shaped --since is out --
say "case 22: the newest marker wins, and --since cannot smuggle a git option"
R22="$S/c22-repo"
mkdir -p "$R22"
g22() { git -C "$R22" "$@"; }
g22 init -q
g22 config user.email test@example.com
g22 config user.name test
g22 config commit.gpgsign false
DB22="$DBT/c22.db"
H22="$(hostname)"
strip_env "$TOOL" add --skill named-twice --db "$DB22" >/dev/null
printf a > "$R22/f"
g22 add f
g22 commit -q -m "skills: the first fix" -m "Skill-log-Fix: $H22#1"
OLDER="$(g22 rev-parse HEAD)"
printf b > "$R22/f"
g22 add f
g22 commit -q -m "skills: the later fix" -m "Skill-log-Fix: $H22#1"
NEWER="$(g22 rev-parse HEAD)"
out="$(cd "$R22" && strip_env "$TOOL" resolve-merged --db "$DB22" --json)"
assert_eq "resolve-merged" "the row named twice is stamped by the newer commit" \
    "$(q13 "$DB22" "SELECT fix FROM invocations WHERE id = 1")" "$NEWER"
if [ "$NEWER" = "$OLDER" ]; then
    fail "resolve-merged" "the two fix commits are not distinct"
fi
out="$(cd "$R22" && strip_env "$TOOL" resolve-merged --since='--output=/tmp/opencode/x' --db "$DB22" 2>&1 >/dev/null)"
st="$(cd "$R22" && strip_env "$TOOL" resolve-merged --since='--output=/tmp/opencode/x' --db "$DB22" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"--since needs a revision"*)
        assert_eq "resolve-merged" "an option-shaped --since is refused" "$st" "2" ;;
    *) fail "resolve-merged" "an option-shaped --since is not refused: $out" ;;
esac

# --- case 23: the hook contract — ours, idempotent, never breaks a pull ----
say "case 23: the hook is idempotent, keeps a foreign hook, and cannot break a pull"
R23="$S/c23-repo"
mkdir -p "$R23"
g23() { git -C "$R23" "$@"; }
g23 init -q -b main
g23 config user.email test@example.com
g23 config user.name test
g23 config commit.gpgsign false
printf base > "$R23/base"
g23 add base
g23 commit -q -m base
HOOK23="$R23/.git/hooks/post-merge"
install23() { (cd "$R23" && sed -n '/^# post-merge: stamp/,$p' "$WORK/scripts/setup-git.sh" | bash) >/dev/null 2>&1; }
if ! install23; then
    fail "hook-install" "the installer failed in a git checkout"
else
    first23="$(sha256sum "$HOOK23" | cut -d' ' -f1)"
    install23
    assert_eq "hook-install" "re-running the installer leaves the hook identical" \
        "$(sha256sum "$HOOK23" | cut -d' ' -f1)" "$first23"
    if find "$R23/.git/hooks" -maxdepth 1 -name 'post-merge.tmp.*' | grep -q .; then
        fail "hook-install" "the installer left a temp file behind"
    else
        ok "hook-install-no-temp"
    fi
fi
rm -f "$HOOK23"
printf '#!/bin/sh\necho foreign hook\n' > "$HOOK23"
chmod +x "$HOOK23"
install23
if grep -qxF 'echo foreign hook' "$HOOK23"; then
    ok "hook-install-foreign-kept"
else
    fail "hook-install" "the installer overwrote a hook it does not own"
fi
# Back to ours, then prove a pull survives the two ways ~/bin/skill-log can be
# unusable: absent, and too old for the subcommand.
install23

rm -f "$HOME/bin/skill-log"
g23 checkout -q -b nobin
printf a > "$R23/f"
g23 add f
g23 commit -q -m "skills: marker with no binary" -m "Skill-log-Fix: box#1"
g23 checkout -q main
if env XDG_STATE_HOME="$S/c23state" git -C "$R23" merge -q --ff-only nobin >/dev/null 2>&1; then
    if [ -e "$S/c23state/skill-log/skills.db" ]; then
        fail "hook-install" "the hook created a db instead of doing nothing"
    else
        ok "hook-install-nobin"
    fi
else
    fail "hook-install" "a missing skill-log broke the pull"
fi

rm -f "$HOME/bin/skill-log"
cat > "$HOME/bin/skill-log" <<'STUB'
#!/bin/sh
echo "skill-log: error: argument command: invalid choice: 'resolve-merged'" >&2
exit 2
STUB
chmod +x "$HOME/bin/skill-log"
g23 checkout -q -b oldbin
printf b > "$R23/f"
g23 add f
g23 commit -q -m "skills: marker with an old binary" -m "Skill-log-Fix: box#1"
g23 checkout -q main
if env XDG_STATE_HOME="$S/c23state" git -C "$R23" merge -q --ff-only oldbin >/dev/null 2>&1; then
    ok "hook-install-oldbin"
else
    fail "hook-install" "an old skill-log broke the pull"
fi
ln -sf "$TOOL" "$HOME/bin/skill-log"
# Outside a git checkout the installer skips cleanly instead of aiming at
# /hooks (it used to mkdir / and fail).
mkdir -p "$S/not-a-repo"
out="$(cd "$S/not-a-repo" && sed -n '/^# post-merge: stamp/,$p' "$WORK/scripts/setup-git.sh" | bash 2>&1)"
st="$?"
case "$out" in
    *"not a git checkout"*)
        assert_eq "hook-install" "a non-git cwd skips with a named reason" "$st" "0" ;;
    *) fail "hook-install" "a non-git cwd does not skip cleanly: $out" ;;
esac

# --- case 24: fix writes the repo report artifact --------------------------
say "case 24: fix writes the repo report file, validated at authoring time"
R24="$S/c24-repo"
mkdir -p "$R24"
g24() { git -C "$R24" "$@"; }
g24 init -q -b main
g24 config user.email test@example.com
g24 config user.name test
g24 config commit.gpgsign false
printf base > "$R24/base"
g24 add base
g24 commit -q -m base
DB24="$DBT/c24.db"
H24="$(hostname)"
strip_env "$TOOL" add --skill report-one --db "$DB24" >/dev/null
strip_env "$TOOL" add --skill report-two --db "$DB24" >/dev/null
strip_env "$TOOL" add --skill report-done --db "$DB24" >/dev/null
strip_env "$TOOL" resolve --id 3 --fix deadbeef --db "$DB24" >/dev/null
strip_env "$TOOL" add --skill report-threaded --opencode-thread ses_c24 --db "$DB24" >/dev/null
"$PYTHON" - "$DB24" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.execute(
    "INSERT INTO invocations (ts, skill, machine, origin_id)"
    " VALUES ('2026-01-01T00:00:00+00:00', 'report-copy', 'otherbox', 7)"
)
con.commit()
con.close()
EOF
REPORT24="$R24/.skill-log/fixes/report.txt"
out="$(cd "$R24" && strip_env "$TOOL" fix --id 1 --slug report --db "$DB24")"
assert_eq "fix" "fix names the report file it wrote" \
    "$(printf '%s' "$out" | sed 's/.* in //')" ".skill-log/fixes/report.txt"
assert_eq "fix" "the report names the marker, not the local id" \
    "$(cat "$REPORT24")" "$H24#1"
(cd "$R24" && strip_env "$TOOL" fix --id 2 --id 3 --slug report --db "$DB24" >/dev/null 2>&1)
assert_eq "fix" "re-running unions, and an already-resolved row stays out" \
    "$(tr '\n' ',' < "$REPORT24")" "$H24#1,$H24#2,"
(cd "$R24" && strip_env "$TOOL" fix --thread ses_c24 --slug report --db "$DB24" >/dev/null)
(cd "$R24" && strip_env "$TOOL" fix --id 5 --slug report --db "$DB24" >/dev/null)
assert_eq "fix" "thread rows arrive, and a copy is reported under its owner" \
    "$(tr '\n' ',' < "$REPORT24")" "$H24#1,$H24#2,$H24#4,otherbox#7,"
out="$(cd "$R24" && strip_env "$TOOL" fix --id 99 --db "$DB24" 2>&1 >/dev/null)"
st="$(cd "$R24" && strip_env "$TOOL" fix --id 99 --db "$DB24" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"no invocation 99"*) assert_eq "fix" "an unknown id is refused" "$st" "1" ;;
    *) fail "fix" "an unknown id is not refused: $out" ;;
esac
st="$(cd "$R24" && strip_env "$TOOL" fix --check --slug report --db "$DB24" >/dev/null 2>&1; echo $?)"
assert_eq "fix" "a well-formed report passes --check" "$st" "0"
printf 'not-a-marker\n' >> "$REPORT24"
out="$(cd "$R24" && strip_env "$TOOL" fix --check --slug report --db "$DB24" 2>&1 >/dev/null)"
st="$(cd "$R24" && strip_env "$TOOL" fix --check --slug report --db "$DB24" >/dev/null 2>&1; echo $?)"
case "$out" in
    *"not a marker (machine#id): not-a-marker"*)
        assert_eq "fix" "a malformed line fails --check" "$st" "1" ;;
    *) fail "fix" "a malformed line is not caught: $out" ;;
esac
st="$(cd "$R24" && strip_env "$TOOL" fix --check --slug absent --db "$DB24" >/dev/null 2>&1; echo $?)"
assert_eq "fix" "a branch with no report is not an error" "$st" "0"
(cd "$R24" && strip_env "$TOOL" fix --id 1 --slug dry --db "$DB24" --dry-run >/dev/null)
if [ -e "$R24/.skill-log/fixes/dry.txt" ]; then
    fail "fix" "a dry run created the report file"
else
    ok "fix-dry-run-writes-nothing"
fi

# --- case 25: a repo with .skill-log/fixes resolves from the report --------
say "case 25: the report file, not the trailer, drives resolution where it exists"
R25="$S/c25-repo"
mkdir -p "$R25/.skill-log/fixes"
: > "$R25/.skill-log/fixes/.gitkeep"
g25() { git -C "$R25" "$@"; }
g25 init -q -b main
g25 config user.email test@example.com
g25 config user.name test
g25 config commit.gpgsign false
printf base > "$R25/base"
g25 add -A
g25 commit -q -m base
(cd "$R25" && sed -n '/^# post-merge: stamp/,$p' "$WORK/scripts/setup-git.sh" | bash) >/dev/null 2>&1
H25="$(hostname)"
DB25="$HOME/.local/state/skill-log/skills.db"
ID25="$(strip_env "$TOOL" add --skill c25-by-file --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
ID25T="$(strip_env "$TOOL" add --skill c25-by-trailer --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
ID25C="$("$PYTHON" - "$DB25" <<'EOF'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
cur = con.execute(
    "INSERT INTO invocations (ts, skill, machine, origin_id)"
    " VALUES ('2026-01-01T00:00:00+00:00', 'c25-copy', 'otherbox', 9)"
)
con.commit()
print(cur.lastrowid)
con.close()
EOF
)"
(cd "$R25" && strip_env "$TOOL" fix --id "$ID25" --id "$ID25C" --slug report >/dev/null)
g25 checkout -q -b report-branch
g25 add -A
g25 commit -q -m "skills: fix by report" -m "Skill-log-Fix: $H25#$ID25T"
FIX25="$(g25 rev-parse HEAD)"
g25 checkout -q main
if ! (cd "$R25" && env -u XDG_STATE_HOME git merge -q --ff-only report-branch >/dev/null 2>"$S/c25.err"); then
    fail "artifact" "the merge with a report file failed"
else
    assert_eq "artifact" "the report file's commit stamps its row" \
        "$(q13 "$DB25" "SELECT fix FROM invocations WHERE id = $ID25")" "$FIX25"
    assert_eq "artifact" "a trailer is not read in artifact mode" \
        "$(q13 "$DB25" "SELECT fix FROM invocations WHERE id = $ID25T")" ""
    case "$(cat "$S/c25.err")" in
        *"resolves from .skill-log/fixes"*) ok "artifact-trailer-ignored" ;;
        *) fail "artifact" "the ignored trailer is not reported" ;;
    esac
    case "$(cat "$S/c25.err")" in
        *"otherbox#9 skipped: merged copy owned by otherbox"*)
            ok "artifact-copy-owner" ;;
        *) fail "artifact" "the copy is not reported with its owner" ;;
    esac
fi
out="$(cd "$R25" && env -u XDG_STATE_HOME git merge --ff-only report-branch 2>&1 |
    grep -E 'resolved|skipped|trailer' || true)"
assert_eq "artifact" "a second merge of the same branch says nothing" "$out" ""

# The reader stands on its own: a full scan of a repo that has the report
# directory resolves from every report file in the tree.
DB25M="$DBT/c25-manual.db"
IDM="$(strip_env "$TOOL" add --skill c25-manual --db "$DB25M" --json |
    "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
printf '%s#%s\n' "$H25" "$IDM" > "$R25/.skill-log/fixes/manual.txt"
g25 add -A
g25 commit -q -m "report two"
out="$(cd "$R25" && strip_env "$TOOL" resolve-merged --db "$DB25M" --json)"
assert_eq "artifact" "a full scan resolves the report file's row" \
    "$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["resolved"]))')" \
    "$H25#$IDM"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
