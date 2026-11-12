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

from std.os import getenv, makedirs
from std.pathlib import Path
from std.time import monotonic, sleep

from sqlite.db import Database
from skill_log.context import local_timestamp
from skill_log.errors import Failure, operational_failure
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


def apply_read_pragmas(db: Database, busy_timeout: Int) raises:
    """The connection settings a read carries.

    Foreign keys so a cascading delete is never silently ignored, and a
    busy timeout so a read behind a writer waits. `journal_mode` is
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
    """
    var opened = StoreOpen()
    if not Path(path).is_file():
        return opened^

    var db = Database(path)

    # The schema check comes before the version check: a file that is
    # not a skill-log store is foreign whatever its stamp says. It comes
    # before the pragmas too, so a refused file is not even touched.
    var refusal = schema_refusal(db, True)
    if refusal.refused():
        refusal.path = path
        opened.refusal = refusal^
        return opened^

    apply_read_pragmas(db, READ_BUSY_TIMEOUT)
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
