"""The store: where it lives, what it holds, and when it is refused.

The store is a SQLite file with one schema — the one ADR-0002 defines, with
explicit harness context in typed columns — stamped with a `PRAGMA
user_version`. 1.0 has no sync: one store per machine, no origin ids, no
merged copies.

Three things are decided here, once, so no command has to decide them
again:

1. **Where the store is.** `--db` first, then `SKILL_LOG_DB`, then
   `${XDG_STATE_HOME:-$HOME/.local/state}/skill-log/skills.db`.
2. **What a store may look like.** The schema below, exactly. A file that
   is not this schema is refused by name; it is never converted and never
   half-migrated.
3. **What a store may be asked to do.** A read never creates the state
   directory, the file, or an empty database. Only a write creates.

The refusal vocabulary is ADR-0002's: a damaged file is *damaged*, a
SQLite file that is not a skill-log store is *foreign*, a store written by
the pre-ADR-0002 schema (the Python era) is *older*, and a store stamped
newer than this binary is *newer*. Every one of them is one named line,
and none of them is written to. The kind is a value (`Refusal`), never a
word inside a message: a path the caller named can contain any word, so a
refusal re-derived from message text would let the path choose the answer.

The write path follows the reference: one transaction covers the
invocation row and every problem row, and a BUSY/LOCKED failure is retried
as a whole attempt inside a small wall-clock budget, because the store is
written by concurrent skill runs.
"""

from std.ffi import OwnedDLHandle, RTLD
from std.os import getenv, makedirs
from std.pathlib import Path
from std.time import monotonic, sleep

from sqlite.db import Database
from skill_log.context import local_timestamp
from skill_log.errors import Failure, operational_failure
from skill_log.ffi import dl_sym
from skill_log.text import sanitize

# The schema version this binary writes and understands. A store stamped
# higher is refused: an older CLI must not touch a newer store.
comptime SCHEMA_VERSION = 1

# The invocation table, exactly as ADR-0002 defines it: one row, explicit
# harness context. Every text column is `NOT NULL DEFAULT ''`, so empty
# means "unknown or not applicable" and the SQL layer stays free of NULL
# semantics.
comptime INVOCATION_DDL = """\
CREATE TABLE IF NOT EXISTS invocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    skill TEXT NOT NULL,
    harness TEXT NOT NULL DEFAULT '',
    session TEXT NOT NULL DEFAULT '',
    parent TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    repo TEXT NOT NULL DEFAULT '',
    worktree TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '',
    t3_thread TEXT NOT NULL DEFAULT '',
    machine TEXT NOT NULL DEFAULT '',
    fix TEXT NOT NULL DEFAULT '',
    resolved_at TEXT NOT NULL DEFAULT ''
)"""

# One problem per finding, keyed by (invocation, ordinal), cascading with
# its invocation.
comptime PROBLEM_DDL = """\
CREATE TABLE IF NOT EXISTS problems (
    invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    problem TEXT NOT NULL,
    PRIMARY KEY (invocation_id, ordinal)
)"""

# The columns a store must carry to be a 1.0 skill-log store. A file that
# carries the two tables but lacks one of these is the pre-ADR-0002 store:
# it is an *older* store, named and refused, never converted.
def store_column_names() -> List[String]:
    """Every invocations column the 1.0 schema has."""
    var names = List[String]()
    names.append("id")
    names.append("ts")
    names.append("skill")
    names.append("harness")
    names.append("session")
    names.append("parent")
    names.append("model")
    names.append("repo")
    names.append("worktree")
    names.append("project")
    names.append("t3_thread")
    names.append("machine")
    names.append("fix")
    names.append("resolved_at")
    return names^

# The write budget, ported from the reference. Concurrent skill runs log
# at once; SQLite's journal-mode conversion and BEGIN can report
# BUSY/LOCKED without honoring the connection busy timeout. The whole
# attempt is retried inside a small wall-clock budget with a short
# per-attempt busy timeout, so a genuinely stuck lock costs a few seconds
# rather than the connect timeout per attempt.
comptime WRITE_BUDGET_SECONDS = 5.0
comptime WRITE_RETRY_SLEEP = 0.1
comptime WRITE_CONNECT_TIMEOUT = 2

# The busy timeout every connection carries, in milliseconds. The write
# path uses the short one; a read may wait longer.
comptime READ_BUSY_TIMEOUT = 5000
comptime WRITE_BUSY_TIMEOUT = WRITE_CONNECT_TIMEOUT * 1000

# --------------------------------------------------------------- paths


def expand_home(path: String) -> String:
    """Expand a leading `~` to the user's home.

    `~` alone is the home directory; `~/x` is `x` inside it. A path that
    does not start with `~` is returned unchanged.
    """
    if not path.startswith("~"):
        return path
    var home = getenv("HOME", "")
    if home == "":
        return path
    if path == "~":
        return home
    if path.startswith("~/"):
        return home + String(path[byte=1:])
    return path


def default_db() -> String:
    """The store path when nothing overrides it.

    `XDG_STATE_HOME` wins; `HOME/.local/state` is the fallback. The
    directory is never created here: a read must not change the machine.
    """
    var xdg = getenv("XDG_STATE_HOME", "")
    var state = xdg
    if state == "":
        state = getenv("HOME", "") + "/.local/state"
    return state + "/skill-log/skills.db"

def resolve_db(flag: String) -> String:
    """The store path: `--db` first, then `SKILL_LOG_DB`, then the default.

    An empty `--db` means the flag was not given, so the environment
    variable gets its turn.
    """
    if flag != "":
        return expand_home(flag)
    var env = getenv("SKILL_LOG_DB", "")
    if env != "":
        return expand_home(env)
    return default_db()


def parent_dir(path: String) -> String:
    """The directory that holds `path`.

    `Path` has no `parent()` in Mojo 1.2, so the split is done here: the
    last separator wins, and a path with no separator has no parent
    directory to create.
    """
    var cut = path.rfind("/")
    if cut <= 0:
        return ""
    return String(path[byte=0:cut])


# --------------------------------------------------------------- refusals


def is_corruption(message: String) -> Bool:
    """True when a SQLite error means the file is not a usable store.

    Not SQLite at all, a malformed page, or an encrypted file. Each is
    damage or a wrong file, and both must be named rather than degraded
    into "no invocations logged yet".
    """
    var text = message.lower()
    return (
        text.find("not a database") != -1
        or text.find("malformed") != -1
        or text.find("file is encrypted") != -1
        or text.find("file is not a database") != -1
    )


def damaged_failure(path: String) -> Failure:
    """The named failure for a file that is not a usable SQLite database."""
    return operational_failure(
        "damaged store: " + path + " is not a skill-log database"
    )


def foreign_failure(path: String) -> Failure:
    """The named failure for a SQLite file that is not a skill-log store."""
    return operational_failure(
        "foreign store: " + path + " is not a skill-log store"
    )


def older_failure(path: String) -> Failure:
    """The named failure for a store written by the pre-ADR-0002 schema.

    The Python-era file carries the old columns and says nothing about
    harness, session or repo. It is a skill-log store, but not this one:
    it is named as older and left exactly as found.
    """
    return operational_failure(
        "older store: " + path + " was written by an older skill-log schema"
        + "; 1.0 does not convert it"
    )


def version_failure(path: String, found: Int) -> Failure:
    """The named failure for a store this binary is too old for."""
    return operational_failure(
        "newer store: " + path + " has schema version "
        + String(found)
        + ", this binary understands "
        + String(SCHEMA_VERSION)
    )


# The refusal kinds, one value per named refusal. A caller compares the
# kind; it never reads the prose back to find out which one it got.
comptime REFUSAL_NONE = 0
comptime REFUSAL_DAMAGED = 1
comptime REFUSAL_FOREIGN = 2
comptime REFUSAL_OLDER = 3
comptime REFUSAL_NEWER = 4


struct Refusal(Movable):
    """A store that was refused, and why.

    The kind is a value rather than a word inside a message. A path the
    caller named can contain any word at all, so a scheme that
    re-derived the kind from the message text would let the path decide
    which refusal the tool reports — `/proc/older/foo.db` would be an
    older store, and `newer5` would surrender a schema version.

    `found` is the version a newer store carries, and zero for every
    other kind.
    """

    var kind: Int
    var path: String
    var found: Int

    def __init__(
        out self, kind: Int = REFUSAL_NONE, path: String = "", found: Int = 0
    ):
        self.kind = kind
        self.path = path
        self.found = found

    def refused(self) -> Bool:
        """True when this names an actual refusal."""
        return self.kind != REFUSAL_NONE

    def failure(self) -> Failure:
        """The named failure for this refusal.

        Called only on a refusal: `refused()` is the caller's check.
        """
        if self.kind == REFUSAL_DAMAGED:
            return damaged_failure(self.path)
        if self.kind == REFUSAL_FOREIGN:
            return foreign_failure(self.path)
        if self.kind == REFUSAL_OLDER:
            return older_failure(self.path)
        if self.kind == REFUSAL_NEWER:
            return version_failure(self.path, self.found)
        return operational_failure("cannot use the store: " + self.path)


# --------------------------------------------------------------- schema


def table_exists(db: Database, name: String) raises -> Bool:
    """True when the database carries a table called `name`."""
    var stmt = db.prepare(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
    )
    stmt.bind_text(1, name)
    var row = stmt.step()
    return row is not None


def columns_of(db: Database, table: String) raises -> List[String]:
    """The column names of `table`, in the table's own order."""
    var names = List[String]()
    var stmt = db.prepare("PRAGMA table_info(" + table + ")")
    while True:
        var row = stmt.step()
        if row is None:
            break
        names.append(row.value().text_val(1))
    return names^


def user_version(db: Database) raises -> Int:
    """The store's schema version stamp. Zero when the file carries none."""
    var stmt = db.prepare("PRAGMA user_version")
    var row = stmt.step()
    if row is None:
        return 0
    return row.value().int_val(0)


def missing_store_columns(db: Database) raises -> List[String]:
    """The 1.0 columns the invocations table lacks.

    Empty means the table carries the current schema. A table that
    carries the two store tables but misses one of these is the
    pre-ADR-0002 store, which is refused rather than converted.
    """
    return missing_columns(db, "invocations", store_column_names())


def store_problem_column_names() -> List[String]:
    """Every problems column the 1.0 schema has."""
    var names = List[String]()
    names.append("invocation_id")
    names.append("ordinal")
    names.append("problem")
    return names^


def missing_problem_columns(db: Database) raises -> List[String]:
    """The 1.0 columns the problems table lacks.

    A file that carries both tables and the right invocations columns
    but a different problems table is not this schema: it is refused as
    foreign, because *writing* into it is what would fail, and it would
    fail after the store had already been accepted.
    """
    return missing_columns(db, "problems", store_problem_column_names())


def missing_columns(
    db: Database, table: String, required: List[String]
) raises -> List[String]:
    """The columns of `required` that `table` does not carry."""
    var missing = List[String]()
    var have = columns_of(db, table)
    for i in range(len(required)):
        var found = False
        for j in range(len(have)):
            if have[j] == required[i]:
                found = True
                break
        if not found:
            missing.append(required[i])
    return missing^


def has_store_tables(db: Database) raises -> Bool:
    """True when both tables of a skill-log store are present."""
    return table_exists(db, "invocations") and table_exists(db, "problems")


def is_skill_log_store(db: Database) raises -> Bool:
    """True when the database carries the 1.0 skill-log schema."""
    if not has_store_tables(db):
        return False
    if len(missing_store_columns(db)) > 0:
        return False
    return len(missing_problem_columns(db)) == 0


def is_older_store(db: Database) raises -> Bool:
    """True when this is a skill-log store written before ADR-0002.

    It carries both tables, so it is ours, but it lacks a column the 1.0
    schema has. The file is named as older and never migrated: moving that
    data belongs to switching a machine's setup, not to the binary.
    """
    if not has_store_tables(db):
        return False
    return len(missing_store_columns(db)) > 0


def stamp_version(db: Database) raises:
    """Write this binary's schema version onto the store."""
    db.execute("PRAGMA user_version=" + String(SCHEMA_VERSION))


# `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`: without it, closing the last
# connection to a WAL store checkpoints its WAL frames into the database
# file and removes the sidecars. That is a write, and a read must not
# write. The option exists in SQLite 3.32+; the bundled library has it.
comptime SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006


def disable_close_checkpoint(db: Database):
    """Ask SQLite not to checkpoint this store when the read closes.

    Best-effort: an older SQLite without the option still reads — it may
    checkpoint on close, which moves committed rows within the store
    rather than changing them. The connection is the vendored binding's,
    and its handle is the one field this needs.
    """
    try:
        var lib = OwnedDLHandle(
            "libsqlite3.so.0", RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
        )
        var config = dl_sym[def(Int, Int, Int, Int) thin abi("C") -> Int32](
            lib, "sqlite3_db_config"
        )
        _ = config(db._handle, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, 0)
    except:
        return


def apply_read_pragmas(db: Database, busy_timeout: Int) raises:
    """The connection settings a read carries.

    Foreign keys so a cascading delete is never silently ignored, a busy
    timeout so a read behind a writer waits. `journal_mode` is
    deliberately absent: switching a file to WAL rewrites its header, and
    a read must not change the machine.
    """
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=" + String(busy_timeout))


def apply_write_pragmas(db: Database, busy_timeout: Int) raises:
    """The connection settings a write carries.

    The read settings plus WAL, so a concurrent reader never blocks a
    writer and a writer never blocks a reader.
    """
    db.execute("PRAGMA journal_mode=WAL")
    apply_read_pragmas(db, busy_timeout)


# --------------------------------------------------------------- opening


def user_table_count(db: Database) raises -> Int:
    """How many ordinary tables the file holds.

    A brand-new SQLite file holds none; a file that already holds
    something else is not ours to convert.
    """
    var stmt = db.prepare(
        "SELECT count(*) FROM sqlite_master"
        " WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    )
    var row = stmt.step()
    if row is None:
        return 0
    return row.value().int_val(0)


struct StoreOpen(Movable):
    """What opening a store produced: the connection, or the refusal.

    `db` is `None` either because the file does not exist (a read that
    never creates) or because the open was refused; `refusal.refused()`
    tells the two apart.
    """

    var db: Optional[Database]
    var refusal: Refusal

    def __init__(out self):
        self.db = None
        self.refusal = Refusal()


def schema_refusal(db: Database, existed: Bool) raises -> Refusal:
    """What, if anything, is wrong with this file's schema.

    A refusal is an answer about the file, so it is returned rather than
    raised: the caller turns it into the named line, and nothing else in
    the write path has to recognise an error. A file with no tables at
    all is not a refusal — it is a store waiting to be initialised — and
    only an *existing* file that already holds something else is foreign.

    The path is filled in by the caller, which is the only place that
    knows it.
    """
    try:
        if is_older_store(db):
            return Refusal(REFUSAL_OLDER, "", 0)

        var ours = is_skill_log_store(db)
        if not ours and existed and (
            user_table_count(db) > 0 or user_version(db) != 0
        ):
            # A concurrent `add` may have committed the schema between
            # those two queries. Ask once more before calling the file
            # foreign: the answer "foreign" is final, and a store that
            # another writer just initialised is not foreign at all.
            ours = is_skill_log_store(db)
            if not ours:
                return Refusal(REFUSAL_FOREIGN, "", 0)

        if ours:
            var found = user_version(db)
            if found > SCHEMA_VERSION:
                return Refusal(REFUSAL_NEWER, "", found)
        return Refusal()
    except e:
        if is_corruption(String(e)):
            return Refusal(REFUSAL_DAMAGED, "", 0)
        raise


def open_read(path: String) raises -> StoreOpen:
    """Open an existing store for reading.

    `db` is `None` when the file does not exist: a read never creates
    the state directory, the file, or an empty database. A file that
    exists but is not a usable store is refused by name; nothing is
    written to it, not even its journal mode.

    Two settings make that true beyond the schema check: the connection
    is put in `query_only` mode, so no statement on it can write, and the
    close-time WAL checkpoint is disabled, so a read does not move the
    store's bytes. SQLite may still leave its `-wal`/`-shm` sidecars
    beside a WAL store, which is how the engine reads one.

    The vendored binding opens read-write (it exposes no open flags), so
    a file deleted between the `is_file` check and the open would be
    recreated. That window is two syscalls wide and no normal writer
    closes it; a genuinely read-only open needs an open-flag seam this
    binding does not have.
    """
    var opened = StoreOpen()
    if not Path(path).is_file():
        return opened^

    var db = Database(path)

    # Before the first read, and before any refusal can return: closing
    # this connection must not checkpoint a WAL into the file, refused or
    # not.
    disable_close_checkpoint(db)

    # The busy timeout is connection state, not file state, so it comes
    # before the schema check: a read that arrives while another process
    # holds the write lock must wait for it, not fail with "database is
    # locked" from the very first `sqlite_master` query. The rest of the
    # pragmas stay after the check, so a refused file is not touched.
    db.execute("PRAGMA busy_timeout=" + String(READ_BUSY_TIMEOUT))

    # The schema check comes before the version check: a file that is
    # not a skill-log store is foreign whatever its stamp says.
    var refusal = schema_refusal(db, True)
    if refusal.refused():
        refusal.path = path
        opened.refusal = refusal^
        return opened^

    apply_read_pragmas(db, READ_BUSY_TIMEOUT)
    # And no statement on this connection may write: a read path that
    # grew a write would fail loudly instead of changing the store. This
    # is set here, never in `apply_read_pragmas`, which the write path
    # also runs.
    db.execute("PRAGMA query_only=ON")
    opened.db = db^
    return opened^


def open_write(path: String) raises -> StoreOpen:
    """Open the store for writing, creating it when it does not exist.

    The state directory and the file are created here, and only here: a
    write is the one thing that may bring a store into being. What this
    file *is* — ours, older, foreign, damaged, newer — is decided before
    anything is written to it.
    """
    var opened = StoreOpen()
    var existed = Path(path).is_file()

    var dir = parent_dir(path)
    if dir != "":
        try:
            makedirs(dir, exist_ok=True)
        except e:
            raise Error("cannot create the store's directory: " + String(e))

    var db = Database(path)

    # The busy timeout comes before the schema check for the same reason
    # it does on the read path: a lock held by another writer must make
    # this attempt wait, not turn a usable store into a refusal. A
    # refusal is final, so it may only follow a read that waited.
    db.execute("PRAGMA busy_timeout=" + String(WRITE_BUSY_TIMEOUT))

    var refusal = schema_refusal(db, existed)
    if refusal.refused():
        refusal.path = path
        opened.refusal = refusal^
        return opened^

    if not is_skill_log_store(db):
        # Both tables, one transaction. Two auto-committed `CREATE`s
        # would leave a window in which a concurrent `add` sees a store
        # with one table and refuses it as foreign, and a failure on the
        # second statement would leave that half-built store behind for
        # good.
        try:
            var tx = db.transaction()
            db.execute(INVOCATION_DDL)
            db.execute(PROBLEM_DDL)
            tx.commit()
        except e:
            raise Error("cannot create the store's schema: " + String(e))

    apply_write_pragmas(db, WRITE_BUSY_TIMEOUT)

    stamp_version(db)
    opened.db = db^
    return opened^


struct Verify(Movable):
    """What `verify` found: a usable store, no file, or a named refusal.

    Exactly the answer the `verify` policy needs (`setup --check`): it
    says whether the machine's store is ready without creating anything
    and without a caller re-deriving the taxonomy from a message or a
    SQLite error.
    """

    var absent: Bool
    var refusal: Refusal

    def __init__(out self):
        self.absent = False
        self.refusal = Refusal()

    def ok(self) -> Bool:
        """True when the file is a usable 1.0 skill-log store."""
        return not self.absent and not self.refusal.refused()


def verify(path: String) raises -> Verify:
    """The store's verdict under the `verify` policy.

    A read that answers instead of failing: a missing file is `absent`,
    a file this tool refuses is that named refusal, and only a store the
    read accepts is `ok`. Nothing is created and nothing is written —
    the same no-write promise `open_read` makes.
    """
    var result = Verify()
    var opened = open_read(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^
    if opened.db is None:
        result.absent = True
        return result^
    return result^


# --------------------------------------------------------------- reading


struct Invocation(Movable):
    """One invocation row, as the store holds it.

    The column order is ADR-0002's, and it is also the order JSON exposes:
    one flat object whose fields a reader can take without a guess.
    """

    var id: Int
    var ts: String
    var skill: String
    var harness: String
    var session: String
    var parent: String
    var model: String
    var repo: String
    var worktree: String
    var project: String
    var t3_thread: String
    var machine: String
    var fix: String
    var resolved_at: String
    var problems: List[String]

    def __init__(out self):
        self.id = 0
        self.ts = ""
        self.skill = ""
        self.harness = ""
        self.session = ""
        self.parent = ""
        self.model = ""
        self.repo = ""
        self.worktree = ""
        self.project = ""
        self.t3_thread = ""
        self.machine = ""
        self.fix = ""
        self.resolved_at = ""
        self.problems = List[String]()

    def marker(self) -> String:
        """The row's marker: `machine#id`.

        The machine is required because ids are per store. A row that has
        not been written has no id yet, so it has no marker either: the
        `--dry-run` preview must not claim a row that does not exist.
        """
        if self.id == 0:
            return ""
        return self.machine + "#" + String(self.id)


def read_invocation(db: Database, id: Int) raises -> Optional[Invocation]:
    """Read one invocation row and its problems.

    The problems are read in ordinal order and sanitized on the way out,
    so one problem is one line whatever the writer stored.
    """
    var stmt = db.prepare(
        "SELECT id, ts, skill, harness, session, parent, model, repo,"
        " worktree, project, t3_thread, machine, fix, resolved_at"
        " FROM invocations WHERE id = ?"
    )
    stmt.bind_int(1, id)
    var row = stmt.step()
    if row is None:
        return None

    var invocation = Invocation()
    invocation.id = row.value().int_val(0)
    invocation.ts = row.value().text_val(1)
    invocation.skill = row.value().text_val(2)
    invocation.harness = row.value().text_val(3)
    invocation.session = row.value().text_val(4)
    invocation.parent = row.value().text_val(5)
    invocation.model = row.value().text_val(6)
    invocation.repo = row.value().text_val(7)
    invocation.worktree = row.value().text_val(8)
    invocation.project = row.value().text_val(9)
    invocation.t3_thread = row.value().text_val(10)
    invocation.machine = row.value().text_val(11)
    invocation.fix = row.value().text_val(12)
    invocation.resolved_at = row.value().text_val(13)

    var problems = db.prepare(
        "SELECT problem FROM problems WHERE invocation_id = ? ORDER BY ordinal"
    )
    problems.bind_int(1, invocation.id)
    while True:
        var problem = problems.step()
        if problem is None:
            break
        invocation.problems.append(sanitize(problem.value().text_val(0)))

    return invocation^


# The number of rows a read returns when the caller does not say. The
# reference's default, and enough to see the recent shape of the log
# without filling a terminal.
comptime DEFAULT_LIMIT = 20

# The filters one read carries. Every field is a string, and an empty
# string means "this filter is not given": the value is matched exactly
# when it is there, and ignored when it is not.
struct Filters(Movable):
    """What one read of the store selects.

    The fields are the store's own column names, except `run`, which
    names a run rather than a column: it matches a row's `session`, its
    `t3_thread` or its `parent` (ADR-0002 §6).
    """

    var skill: String
    var machine: String
    var harness: String
    var repo: String
    var run: String
    var unresolved: Bool
    var limit: Int

    def __init__(out self):
        self.skill = ""
        self.machine = ""
        self.harness = ""
        self.repo = ""
        self.run = ""
        self.unresolved = False
        self.limit = DEFAULT_LIMIT


def filter_clause(filters: Filters) -> String:
    """The `WHERE` clause the filters ask for, without the keyword.

    Empty when no filter is given, so the query has no `WHERE` at all.
    Each filter is a bound parameter, never text spliced into the SQL.
    """
    var clauses = List[String]()
    if filters.skill != "":
        clauses.append("skill = ?")
    if filters.machine != "":
        clauses.append("machine = ?")
    if filters.harness != "":
        clauses.append("harness = ?")
    if filters.repo != "":
        clauses.append("repo = ?")
    if filters.run != "":
        # ADR-0002 §6: `--run <id>` names a run, and a row names that run
        # in its session, its T3 thread or its parent.
        clauses.append("(session = ? OR t3_thread = ? OR parent = ?)")
    if filters.unresolved:
        clauses.append("fix = ''")
    if len(clauses) == 0:
        return ""
    var out = " WHERE "
    for i in range(len(clauses)):
        if i > 0:
            out += " AND "
        out += clauses[i]
    return out


def filter_parameters(filters: Filters) -> List[String]:
    """The values the filter clause binds, in the clause's order."""
    var marks = List[String]()
    if filters.skill != "":
        marks.append(filters.skill)
    if filters.machine != "":
        marks.append(filters.machine)
    if filters.harness != "":
        marks.append(filters.harness)
    if filters.repo != "":
        marks.append(filters.repo)
    if filters.run != "":
        # The run filter binds three placeholders: one each for the
        # session, the T3 thread and the parent.
        marks.append(filters.run)
        marks.append(filters.run)
        marks.append(filters.run)
    return marks^


def read_invocations(db: Database, filters: Filters) raises -> List[Invocation]:
    """Read the invocation rows the filters select, newest first.

    The ordering is `datetime(ts) DESC, id DESC`: `datetime()` normalizes
    each row's ISO stamp (rows carry their writer's own UTC offset) so the
    rows sort by when the run happened, not by when it was written. The id
    breaks a tie between two rows of the same instant, so the order is
    total and stable.

    Every problem is read with its row, in ordinal order and sanitized on
    the way out, so one problem is one line whatever the writer stored.

    `filters.limit` of zero means every matching row: `show` always asks
    for 1..500, and `report` must not cap a selection it is stamping.
    """
    var clause = filter_clause(filters)
    var marks = filter_parameters(filters)

    # A limit of zero means "every matching row": `report` selects the
    # rows a change fixes and must not silently drop the tail of a large
    # selection. `show` always passes 1..500.
    var limit = " LIMIT ?"
    if filters.limit <= 0:
        limit = ""

    var stmt = db.prepare(
        "SELECT id, ts, skill, harness, session, parent, model, repo,"
        " worktree, project, t3_thread, machine, fix, resolved_at"
        " FROM invocations" + clause
        + " ORDER BY datetime(ts) DESC, id DESC" + limit
    )

    # The filter values bind first, in the clause's order, and the limit
    # binds last.
    for i in range(len(marks)):
        stmt.bind_text(i + 1, marks[i])
    if filters.limit > 0:
        stmt.bind_int(len(marks) + 1, filters.limit)

    var rows = List[Invocation]()
    while True:
        var row = stmt.step()
        if row is None:
            break

        var invocation = Invocation()
        invocation.id = row.value().int_val(0)
        invocation.ts = row.value().text_val(1)
        invocation.skill = row.value().text_val(2)
        invocation.harness = row.value().text_val(3)
        invocation.session = row.value().text_val(4)
        invocation.parent = row.value().text_val(5)
        invocation.model = row.value().text_val(6)
        invocation.repo = row.value().text_val(7)
        invocation.worktree = row.value().text_val(8)
        invocation.project = row.value().text_val(9)
        invocation.t3_thread = row.value().text_val(10)
        invocation.machine = row.value().text_val(11)
        invocation.fix = row.value().text_val(12)
        invocation.resolved_at = row.value().text_val(13)

        var problems = db.prepare(
            "SELECT problem FROM problems WHERE invocation_id = ? ORDER BY ordinal"
        )
        problems.bind_int(1, invocation.id)
        while True:
            var problem = problems.step()
            if problem is None:
                break
            invocation.problems.append(sanitize(problem.value().text_val(0)))

        rows.append(invocation^)

    return rows^


# -------------------------------------------------------------- counting


def group_columns() -> List[String]:
    """The columns a count may be grouped by, default first.

    `skill` leads because friction is per skill before it is per anything
    else, and it is what a bare `stats` reports. The rest are ADR-0002's
    context columns — the cuts that separate an instruction defect from
    environment noise.
    """
    var columns = List[String]()
    columns.append("skill")
    columns.append("harness")
    columns.append("model")
    columns.append("repo")
    columns.append("worktree")
    columns.append("machine")
    columns.append("project")
    return columns^


def is_group_column(name: String) -> Bool:
    """True when `name` is one of the columns `stats` may group by.

    The one allow-list. `stats` validates its flag against it, and the
    query below refuses anything else, so no caller can put a column
    name into the SQL text without having been through this check.
    """
    var columns = group_columns()
    for i in range(len(columns)):
        if columns[i] == name:
            return True
    return False


struct GroupCount(Movable):
    """One line of the stats table: a group's key and its four counts.

    `with_problems` counts invocations that have at least one problem,
    and `problems` counts problem rows. They differ by design: the rate's
    denominator is invocations, so a run with two findings is one run and
    two problems, and a group's friction is not inflated by how many
    findings one run happened to produce.
    """

    var key: String
    var invocations: Int
    var with_problems: Int
    var problems: Int
    var resolved: Int

    def __init__(out self):
        self.key = ""
        self.invocations = 0
        self.with_problems = 0
        self.problems = 0
        self.resolved = 0


def read_group_counts(
    db: Database, column: String, skill: String
) raises -> List[GroupCount]:
    """Count the invocations and problems per value of `column`.

    `COUNT(DISTINCT i.id)` is the denominator and the only honest count:
    the LEFT JOIN produces one line per problem, so `COUNT(*)` would
    count problems and `COUNT(DISTINCT i.id)` counts runs. `p` is joined
    rather than sub-queried so a run with no problems still appears, with
    zeroes, which is what the rate's denominator requires.

    `skill` narrows the whole cut to one skill; empty means every skill.
    `column` must have passed `is_group_column`.
    """
    if not is_group_column(column):
        raise Error("not a groupable column: " + column)

    var where = ""
    if skill != "":
        where = " WHERE i.skill = ?"

    var stmt = db.prepare(
        "SELECT i." + column + " AS group_key,"
        " COUNT(DISTINCT i.id),"
        " COUNT(DISTINCT p.invocation_id),"
        " COUNT(p.ordinal),"
        " COUNT(DISTINCT CASE WHEN i.fix <> '' THEN i.id END)"
        " FROM invocations i"
        " LEFT JOIN problems p ON p.invocation_id = i.id"
        + where
        + " GROUP BY i." + column
        + " ORDER BY i." + column
    )
    if skill != "":
        stmt.bind_text(1, skill)

    var groups = List[GroupCount]()
    while True:
        var row = stmt.step()
        if row is None:
            break
        var group = GroupCount()
        group.key = row.value().text_val(0)
        group.invocations = row.value().int_val(1)
        group.with_problems = row.value().int_val(2)
        group.problems = row.value().int_val(3)
        group.resolved = row.value().int_val(4)
        groups.append(group^)
    return groups^


# --------------------------------------------------------------- writing


def is_busy(message: String) -> Bool:
    """True when a SQLite error means the store was busy or locked."""
    var text = message.lower()
    return text.find("locked") != -1 or text.find("busy") != -1


def now_seconds() -> Float64:
    """A monotonic clock reading in seconds, for the write budget.

    The retry budget only needs a clock that does not run backwards;
    `monotonic` is exactly that.
    """
    return Float64(monotonic()) / 1_000_000_000.0


struct WriteResult(Movable):
    """What a write produced: the new row's id, or the refusal.

    One or the other, never both: `refusal.refused()` false means `id`
    names the row that was committed.
    """

    var id: Int
    var refusal: Refusal

    def __init__(out self):
        self.id = 0
        self.refusal = Refusal()


def write_invocation(
    path: String, mut row: Invocation, mut problems: List[String]
) raises -> WriteResult:
    """Write one invocation and its problems, atomically.

    One transaction covers the invocation row and every problem row: a
    failed write leaves nothing behind. A BUSY/LOCKED failure is retried
    as a whole attempt inside the write budget, because a concurrent
    skill run holding the lock costs milliseconds, not the command.

    A refused store is not an exception: the result carries the refusal,
    and the caller reports it by name. Only a genuine SQLite failure
    raises.

    The returned id is the row's local id. The row's timestamp is
    stamped here, from the same connection and inside the same
    transaction, so the row carries the moment it was written.
    """
    var deadline = now_seconds() + WRITE_BUDGET_SECONDS

    while True:
        try:
            return write_attempt(path, row, problems)
        except e:
            var message = String(e)
            if not is_busy(message):
                raise
            var remaining = deadline - now_seconds()
            if remaining <= 0:
                raise
            sleep(min(Float64(WRITE_RETRY_SLEEP), remaining))


def write_attempt(
    path: String, mut row: Invocation, mut problems: List[String]
) raises -> WriteResult:
    """One write attempt: open, insert, insert, commit.

    The transaction guard rolls back when an insert fails, so a partial
    write is impossible. The invocation row is inserted first and its
    id is read back inside the same transaction.
    """
    var result = WriteResult()

    var opened = open_write(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^

    var db = opened.db.take()

    var tx = db.transaction()

    row.ts = local_timestamp(db)

    var stmt = db.prepare(
        "INSERT INTO invocations"
        " (ts, skill, harness, session, parent, model, repo, worktree,"
        " project, t3_thread, machine, fix, resolved_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    stmt.bind_text(1, row.ts)
    stmt.bind_text(2, row.skill)
    stmt.bind_text(3, row.harness)
    stmt.bind_text(4, row.session)
    stmt.bind_text(5, row.parent)
    stmt.bind_text(6, row.model)
    stmt.bind_text(7, row.repo)
    stmt.bind_text(8, row.worktree)
    stmt.bind_text(9, row.project)
    stmt.bind_text(10, row.t3_thread)
    stmt.bind_text(11, row.machine)
    stmt.bind_text(12, row.fix)
    stmt.bind_text(13, row.resolved_at)
    _ = stmt.step()

    var last = db.prepare("SELECT last_insert_rowid()")
    var id_row = last.step()
    var id = 0
    if id_row is not None:
        id = id_row.value().int_val(0)

    var problem_stmt = db.prepare(
        "INSERT INTO problems (invocation_id, ordinal, problem) VALUES (?, ?, ?)"
    )
    for i in range(len(problems)):
        # A statement that has reached SQLITE_DONE must be reset before it
        # is bound again: SQLite answers a bind on a finished statement
        # with SQLITE_MISUSE.
        problem_stmt.reset()
        problem_stmt.bind_int(1, id)
        problem_stmt.bind_int(2, i + 1)
        problem_stmt.bind_text(3, problems[i])
        _ = problem_stmt.step()

    result.id = id
    tx.commit()
    return result^


# -------------------------------------------------------------- resolution


struct ResolvedRow(Movable):
    """One row's resolution after `resolve` touched it (or looked at it).

    `changed` is false when the row already carried the same fix: the
    call is idempotent, and the stored `resolved_at` stays the one the
    first stamp wrote rather than moving on every retry. `refusal` is the
    store refusal when the file could not be used at all.
    """

    var found: Bool
    var skill: String
    var machine: String
    var fix: String
    var resolved_at: String
    var changed: Bool
    var refusal: Refusal

    def __init__(out self):
        self.found = False
        self.skill = ""
        self.machine = ""
        self.fix = ""
        self.resolved_at = ""
        self.changed = False
        self.refusal = Refusal()


def resolve_row(
    path: String, id: Int, fix: String, dry_run: Bool
) raises -> ResolvedRow:
    """Stamp one row with the commit that carries its fix.

    The read comes first and through a read connection: a row already
    carrying this fix is answered without a write at all, and a dry run
    never opens the store for writing. Only a genuine change opens the
    write path, inside the same whole-attempt busy retry `add` uses.

    The commit and the timestamp are written together; the timestamp is
    read from SQLite in the same transaction, so the stamp is the moment
    the row was resolved. A refusal is a value, never an exception.
    """
    var result = ResolvedRow()

    var opened = open_read(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^
    if not opened.db:
        return result^

    var db = opened.db.take()
    # An existing file with no store tables yet is an empty log, not an
    # error: the id it is asked for cannot exist.
    if not is_skill_log_store(db):
        return result^
    var row = read_invocation(db, id)
    if not row:
        return result^

    result.found = True
    result.skill = row.value().skill
    result.machine = row.value().machine
    result.fix = fix

    if row.value().fix == fix:
        # The same fix again is a no-op: keep the first stamp's time.
        result.resolved_at = row.value().resolved_at
        return result^

    if dry_run:
        # A preview reads the clock the write would read, through the
        # same store connection, and writes nothing.
        result.resolved_at = local_timestamp(db)
        result.changed = True
        return result^

    var deadline = now_seconds() + WRITE_BUDGET_SECONDS
    while True:
        try:
            return stamp_attempt(path, id, fix)
        except e:
            var message = String(e)
            if not is_busy(message):
                raise
            var remaining = deadline - now_seconds()
            if remaining <= 0:
                raise
            sleep(min(Float64(WRITE_RETRY_SLEEP), remaining))


def stamp_attempt(path: String, id: Int, fix: String) raises -> ResolvedRow:
    """One write attempt: open, re-read inside the transaction, stamp.

    The row is read again here, under the write transaction, because the
    earlier read was only a fast path: two concurrent resolves of the
    same fix would otherwise both see the old value and both write a new
    timestamp. Inside the transaction the second one finds the fix it was
    about to write and answers `changed = false` instead. A busy failure
    on the snapshot re-runs the whole attempt, so it rechecks too.

    The transaction guard rolls back if the update fails, so a row is
    either fully stamped or untouched.
    """
    var result = ResolvedRow()
    var opened = open_write(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^

    var db = opened.db.take()
    var tx = db.transaction()

    var read = db.prepare(
        "SELECT skill, machine, fix, resolved_at FROM invocations WHERE id = ?"
    )
    read.bind_int(1, id)
    var row = read.step()
    if row is None:
        # Nothing to stamp; the transaction has written nothing.
        _ = tx^
        return result^

    result.found = True
    result.skill = row.value().text_val(0)
    result.machine = row.value().text_val(1)
    result.fix = fix

    if row.value().text_val(2) == fix:
        # Another writer (or our own earlier attempt) already installed
        # this fix: keep its timestamp and change nothing.
        result.resolved_at = row.value().text_val(3)
        _ = tx^
        return result^

    var stamp = local_timestamp(db)
    var stmt = db.prepare(
        "UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?"
    )
    stmt.bind_text(1, fix)
    stmt.bind_text(2, stamp)
    stmt.bind_int(3, id)
    _ = stmt.step()

    result.resolved_at = stamp
    result.changed = True
    tx.commit()
    return result^


# ------------------------------------------------------------ merged scans


# The skip reasons `resolve-merged` reports. SPEC §5.10 fixes these
# tokens: the `--json` `skipped[].reason` and the human note carry the
# same value, so a caller never has to match prose.
comptime SKIP_UNKNOWN_ID = "unknown_id"
comptime SKIP_FOREIGN = "foreign"
comptime SKIP_LOGGED_AFTER = "logged_after_commit"


struct Located(Movable):
    """One marker the scan found, and the commit and time it came from.

    A marker parses to `machine#id`; the commit and its epoch are the
    stamp and the guard. The epoch is the commit time in seconds, which
    is what a row logged after the commit is compared against. This is
    the scan's yield: only the resolution plan consumes it.
    """

    var machine: String
    var id: Int
    var commit: String
    var epoch: Int

    def __init__(
        out self,
        machine: String = "",
        id: Int = 0,
        commit: String = "",
        epoch: Int = 0,
    ):
        self.machine = machine
        self.id = id
        self.commit = commit
        self.epoch = epoch

    def text(self) -> String:
        """The marker this located value is named by."""
        return self.machine + "#" + String(self.id)


struct MergedSkip(Movable):
    """One marker a scan could not stamp, and the reason it was skipped.

    The reason is a fixed token (SPEC §5.10): `unknown_id`, `foreign`
    or `logged_after_commit`. The human note wraps it, but the value a
    `--json` caller reads is the token.
    """

    var row: String
    var reason: String

    def __init__(out self, row: String = "", reason: String = ""):
        self.row = row
        self.reason = reason


struct MergedResult(Movable):
    """What a merged scan produced: the rows it stamped, kept, and skipped.

    `refusal` is the store refusal when the file could not be used at
    all. A dry run fills the same three lists and writes nothing.
    """

    var stamped: List[String]
    var unchanged: List[String]
    var skipped: List[MergedSkip]
    var refusal: Refusal

    def __init__(out self):
        self.stamped = List[String]()
        self.unchanged = List[String]()
        self.skipped = List[MergedSkip]()
        self.refusal = Refusal()


struct ResolutionRow(Movable):
    """The columns a merged scan needs from one invocation row.

    `logged` is the row's timestamp in epoch seconds, read by SQLite so
    the comparison against a commit time does not need a second ISO
    parser. An unparseable timestamp reads as zero, which disables the
    guard instead of silently skipping the row.
    """

    var id: Int
    var machine: String
    var fix: String
    var logged: Int

    def __init__(out self):
        self.id = 0
        self.machine = ""
        self.fix = ""
        self.logged = 0


def read_resolution_rows(db: Database) raises -> List[ResolutionRow]:
    """Every row's id, machine, fix and timestamp, in one read."""
    var rows = List[ResolutionRow]()
    var stmt = db.prepare(
        "SELECT id, machine, fix, COALESCE(unixepoch(ts), 0)"
        " FROM invocations"
    )
    while True:
        var row = stmt.step()
        if row is None:
            break
        var item = ResolutionRow()
        item.id = row.value().int_val(0)
        item.machine = row.value().text_val(1)
        item.fix = row.value().text_val(2)
        item.logged = row.value().int_val(3)
        rows.append(item^)
    return rows^


def merged_row_index(
    rows: List[ResolutionRow], machine: String, id: Int, local_host: String
) -> Int:
    """The index of the row a marker names, or -1.

    A row written before `add` always populated the machine column has
    an empty machine; it belongs to the machine reading it, which is the
    reference's rule too.
    """
    for i in range(len(rows)):
        var stored = rows[i].machine
        if stored == "":
            stored = local_host
        if stored == machine and rows[i].id == id:
            return i
    return -1


def plan(
    located: List[Located],
    rows: List[ResolutionRow],
    local_host: String,
) -> MergedResult:
    """Decide each located marker: stamp, unchanged, or skip with a reason.

    Pure: no git, no clock, no store. The caller owns the scan (which
    yields `located`) and the writer (`apply`, via `resolve_merged_rows`);
    this only decides. Every marker lands in exactly one of the three
    lists, so a second scan that finds the row already carrying this
    commit answers `unchanged` instead of stamping again.

    Newest wins because the scan walks commits newest first and the plan
    sees one marker per row. A row stamped with the *same* commit is
    unchanged; a row stamped with a *different* commit is restamped, so
    an amended fix supersedes the earlier one — idempotency is a second
    scan seeing the same commit, not a freeze on the first fix.

    A marker whose machine is not this host's spelling is foreign and is
    never stamped (SPEC §2). The rows this store holds do not change
    that: a row carrying another machine's name is a row this machine
    does not own, and its id is not this store's to stamp. The one
    exception the store has always had is a row with an *empty* machine
    column — written before `add` always filled it — and that row
    belongs to the machine reading it.
    """
    var result = MergedResult()
    for i in range(len(located)):
        var marker = located[i].text()
        if located[i].machine != local_host:
            # A marker naming another machine: its store is elsewhere.
            # Reported, never stamped.
            var foreign = MergedSkip(marker, SKIP_FOREIGN)
            result.skipped.append(foreign^)
            continue
        var index = merged_row_index(
            rows, located[i].machine, located[i].id, local_host
        )
        if index == -1:
            # A local marker whose id this store does not hold.
            var missing = MergedSkip(marker, SKIP_UNKNOWN_ID)
            result.skipped.append(missing^)
            continue
        if rows[index].fix != "" and rows[index].fix == located[i].commit:
            # The same fix again: the row already carries this commit,
            # so a second scan changes nothing.
            result.unchanged.append(marker)
            continue
        if rows[index].logged > located[i].epoch:
            # The row was written after that commit: an id reused by a
            # rebuilt log, not the row the commit fixed.
            var later = MergedSkip(marker, SKIP_LOGGED_AFTER)
            result.skipped.append(later^)
            continue
        # An empty fix, or a different one: the row is stamped with this
        # commit. A differing commit is a restamp, so an amended fix
        # supersedes the earlier one.
        result.stamped.append(marker)
    return result^


def resolve_merged_rows(
    path: String,
    located: List[Located],
    local_host: String,
    dry_run: Bool,
) raises -> MergedResult:
    """Apply: stamp every row the scanned markers name.

    The first pass reads through a read connection: when nothing would
    change (the hook's usual case) no write path is opened at all, and a
    dry run never gets one either. A genuine change opens the store once,
    under the same whole-attempt busy retry `add` uses, re-decides inside
    a transaction, and stamps every changed row with one resolution time.
    """
    var result = MergedResult()
    if len(located) == 0:
        return result^
    if not Path(path).is_file():
        # The store vanished between the caller's check and here. A hook
        # must not create one.
        return result^

    var opened = open_read(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^
    if not opened.db:
        return result^

    var db = opened.db.take()
    var rows = List[ResolutionRow]()
    if is_skill_log_store(db):
        rows = read_resolution_rows(db)
    var preview = plan(located, rows, local_host)
    if dry_run or len(preview.stamped) == 0:
        return preview^

    var deadline = now_seconds() + WRITE_BUDGET_SECONDS
    while True:
        try:
            return merged_write_attempt(path, located, local_host)
        except e:
            var message = String(e)
            if not is_busy(message):
                raise
            var remaining = deadline - now_seconds()
            if remaining <= 0:
                raise
            sleep(min(Float64(WRITE_RETRY_SLEEP), remaining))


def merged_write_attempt(
    path: String, located: List[Located], local_host: String
) raises -> MergedResult:
    """The writer `apply`: open, re-read, re-decide, stamp, commit.

    Applying the plan is the only write. One timestamp is read inside
    the transaction and written to every row this attempt resolves, so a
    pull's rows share the moment they closed.
    """
    var result = MergedResult()
    if not Path(path).is_file():
        # The store vanished after the preview. A hook must not create a
        # new store, so this is nothing to do, not a write.
        return result^
    var opened = open_write(path)
    if opened.refusal.refused():
        result.refusal = Refusal(
            opened.refusal.kind, opened.refusal.path, opened.refusal.found
        )
        return result^

    var db = opened.db.take()
    var tx = db.transaction()
    var stamp = local_timestamp(db)
    var rows = read_resolution_rows(db)
    var resolved = plan(located, rows, local_host)
    if len(resolved.stamped) == 0:
        # A concurrent writer closed every row between the preview and
        # here. There is nothing to commit; the guard rolls back.
        _ = tx^
        return resolved^
    # One prepared statement, reset per row: preparing inside the loop
    # leaves the earlier statement unfinalized in this binding, and the
    # transaction's COMMIT then fails with SQLITE_MISUSE.
    var update = db.prepare(
        "UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?"
    )
    for i in range(len(resolved.stamped)):
        var target_index = -1
        for j in range(len(located)):
            if located[j].text() == resolved.stamped[i]:
                target_index = j
                break
        if target_index == -1:
            continue
        var row_index = merged_row_index(
            rows,
            located[target_index].machine,
            located[target_index].id,
            local_host,
        )
        if row_index == -1:
            continue
        update.reset()
        update.bind_text(1, located[target_index].commit)
        update.bind_text(2, stamp)
        update.bind_int(3, rows[row_index].id)
        _ = update.step()
    tx.commit()
    return resolved^
