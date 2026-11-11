"""The store: where it lives, what it holds, and when it is refused.

The store is a SQLite file with one schema, and the schema is a contract
with the tool's own history: the same file the Python-era implementation
wrote, plus a `PRAGMA user_version` stamp. 1.0 has no sync, so `origin_id`
stays in the schema for compatibility but the sync index is optional.

Three things are decided here, once, so no command has to decide them
again:

1. **Where the store is.** `--db` first, then `SKILL_LOG_DB`, then
   `${XDG_STATE_HOME:-$HOME/.local/state}/skill-log/skills.db`.
2. **What a store may look like.** The schema below, exactly. A file that
   is not this schema is refused by name; it is never converted.
3. **What a store may be asked to do.** A read never creates the state
   directory, the file, or an empty database. Only a write creates.

The refusal vocabulary is the one issue #1 fixes: a damaged file is
*damaged*, a SQLite file that is not a skill-log store is *foreign*, and a
store stamped newer than this binary is *newer*. An older store converges
additively: one `ALTER` per missing column, never a half-migration.

The write path is ported from the Python reference: one transaction covers
the invocation row and every problem row, and a BUSY/LOCKED failure is
retried as a whole attempt inside a small wall-clock budget, because the
store is written by concurrent skill runs.
"""

from std.os import getenv, makedirs
from std.pathlib import Path
from std.time import monotonic, sleep

from sqlite.db import Database
from skill_log.context import local_timestamp
from skill_log.errors import Failure, operational_failure

# The schema version this binary writes and understands. A store stamped
# higher is refused: an older CLI must not touch a newer store.
#
# Version 1 is the schema below. It is additive: a later release adds
# columns and raises the number; migrations converge an older file
# forward, never a newer one backward.
comptime SCHEMA_VERSION = 1

# The invocation table. Column names, types and defaults are the
# reference's, byte for byte, so a store written by either implementation
# is readable by the other.
#
# `origin_id` stays for compatibility with the sync-era store even though
# 1.0 has no sync: a local row has origin id 0.
comptime INVOCATION_DDL = """\
CREATE TABLE IF NOT EXISTS invocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    skill TEXT NOT NULL,
    parent TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    project TEXT NOT NULL DEFAULT '',
    t3_thread TEXT NOT NULL DEFAULT '',
    opencode_thread TEXT NOT NULL DEFAULT '',
    worktree TEXT NOT NULL DEFAULT '',
    machine TEXT NOT NULL DEFAULT '',
    fix TEXT NOT NULL DEFAULT '',
    resolved_at TEXT NOT NULL DEFAULT '',
    origin_id INTEGER NOT NULL DEFAULT 0
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

# The dedupe key for rows a sync merged in. 1.0 has no sync, so the index
# is optional: it is created when it can be, and its absence never blocks
# a write.
comptime ORIGIN_INDEX_DDL = """\
CREATE UNIQUE INDEX IF NOT EXISTS invocations_origin
    ON invocations(machine, origin_id) WHERE origin_id > 0"""

# The columns that arrived after the first schema. A store older than one
# of them gets one `ALTER` per column it lacks, not an error.
#
# Two parallel lists rather than pairs: Mojo 1.2 cannot index a tuple
# with a runtime index, and the convergence loop needs one. They are
# built per call rather than kept in a global, because Mojo has no
# globals and a `comptime` list of strings cannot be materialised at
# runtime.
def known_column_names() -> List[String]:
    """The columns a store may predate, in convergence order."""
    var names = List[String]()
    names.append("model")
    names.append("parent")
    names.append("fix")
    names.append("resolved_at")
    names.append("origin_id")
    return names^


def known_column_decls() -> List[String]:
    """The declaration each converge column is added with."""
    var decls = List[String]()
    decls.append("TEXT NOT NULL DEFAULT ''")
    decls.append("TEXT NOT NULL DEFAULT ''")
    decls.append("TEXT NOT NULL DEFAULT ''")
    decls.append("TEXT NOT NULL DEFAULT ''")
    decls.append("INTEGER NOT NULL DEFAULT 0")
    return decls^


# The columns a store must carry to be a skill-log store at all. A SQLite
# file without them is foreign and is refused, never adopted.
def required_column_names() -> List[String]:
    """The columns without which a file is not a skill-log store."""
    var names = List[String]()
    names.append("id")
    names.append("ts")
    names.append("skill")
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

# The control characters the reference strips on read: C0 minus tab, plus
# DEL. A newline becomes a space so one problem stays one line and cannot
# inject a terminal escape. The set itself lives in `is_control`.


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


def version_failure(path: String, found: Int) -> Failure:
    """The named failure for a store this binary is too old for."""
    return operational_failure(
        "newer store: " + path + " has schema version "
        + String(found)
        + ", this binary understands "
        + String(SCHEMA_VERSION)
    )


def newer_marker(found: Int) -> Error:
    """The marker the store raises for a store that is too new.

    The found version rides in the message, so the refusal can name it
    without a second query against a store that may be newer still.
    """
    return Error("newer " + String(found))


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


def has_column(db: Database, name: String) raises -> Bool:
    """True when the invocations table carries a column called `name`."""
    var names = columns_of(db, "invocations")
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def ensure_columns(db: Database) raises:
    """Converge an older store forward: one `ALTER` per missing column.

    A column that is already there is a no-op. A losing `ALTER` against a
    parallel writer that won the race means the column exists, which is
    all this check owns, so that case is swallowed; every other failure
    is the caller's to report.
    """
    var names = known_column_names()
    var decls = known_column_decls()
    for i in range(len(names)):
        var name = names[i]
        var decl = decls[i]
        if has_column(db, name):
            continue
        try:
            db.execute("ALTER TABLE invocations ADD COLUMN " + name + " " + decl)
        except e:
            if not has_column(db, name):
                raise Error(
                    "cannot converge the store's schema: " + String(e)
                )


def user_version(db: Database) raises -> Int:
    """The store's schema version stamp. Zero when the file carries none."""
    var stmt = db.prepare("PRAGMA user_version")
    var row = stmt.step()
    if row is None:
        return 0
    return row.value().int_val(0)


def is_skill_log_store(db: Database) raises -> Bool:
    """True when the database carries the skill-log schema.

    The invocations table must exist with the columns every store has,
    and the problems table must exist beside it.
    """
    if not table_exists(db, "invocations"):
        return False
    if not table_exists(db, "problems"):
        return False
    var names = columns_of(db, "invocations")
    var required = required_column_names()
    for i in range(len(required)):
        var found = False
        for j in range(len(names)):
            if names[j] == required[i]:
                found = True
                break
        if not found:
            return False
    return True


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


def open_read(path: String) raises -> Optional[Database]:
    """Open an existing store for reading.

    `None` when the file does not exist: a read never creates the state
    directory, the file, or an empty database. A file that exists but is
    not a usable store is refused by name; nothing is written.
    """
    if not Path(path).is_file():
        return None

    var db = Database(path)

    # The schema check comes before the version check: a file that is
    # not a skill-log store is foreign whatever its stamp says. It comes
    # before the pragmas too, so a refused file is not even touched.
    try:
        var store = is_skill_log_store(db)
        if not store:
            raise Error("foreign")
        var found = user_version(db)
        if found > SCHEMA_VERSION:
            raise newer_marker(found)
    except e:
        if is_corruption(String(e)):
            raise Error("damaged")
        raise

    apply_read_pragmas(db, READ_BUSY_TIMEOUT)

    # An older store converges additively on first touch, so a command
    # that reads a column it needs finds it.
    try:
        ensure_columns(db)
    except e:
        if is_corruption(String(e)):
            raise Error("damaged")
        raise

    return db^


def open_write(path: String) raises -> Database:
    """Open the store for writing, creating it when it does not exist.

    The state directory and the file are created here, and only here: a
    write is the one thing that may bring a store into being.
    """
    var existed = Path(path).is_file()

    var dir = parent_dir(path)
    if dir != "":
        try:
            makedirs(dir, exist_ok=True)
        except e:
            raise Error("cannot create the store's directory: " + String(e))

    var db = Database(path)

    # Decide what this file is before touching it. A refused store is not
    # even switched to WAL: "nothing written" includes its header.
    try:
        var store = is_skill_log_store(db)
        if not store:
            # A file that already holds something else is never converted.
            # An empty SQLite file (or one we just created) has no tables,
            # and neither has a stamp, so it is ours to initialise.
            if existed and (user_table_count(db) > 0 or user_version(db) != 0):
                raise Error("foreign")
            db.execute(INVOCATION_DDL)
            db.execute(PROBLEM_DDL)
        var found = user_version(db)
        if found > SCHEMA_VERSION:
            raise newer_marker(found)
    except e:
        if is_corruption(String(e)):
            raise Error("damaged")
        raise

    apply_write_pragmas(db, WRITE_BUSY_TIMEOUT)

    ensure_columns(db)

    # The sync index is optional in 1.0: a store whose merged copies
    # collide cannot have it, and that must not block a local write.
    try:
        db.execute(ORIGIN_INDEX_DDL)
    except:
        pass

    stamp_version(db)
    return db^


def classify(path: String, message: String) -> Failure:
    """The named failure for a refused store.

    The store module raises `damaged`, `foreign` and `newer <version>` as
    markers; this turns one into the line the user sees.
    """
    if message.find("damaged") != -1:
        return damaged_failure(path)
    if message.find("foreign") != -1:
        return foreign_failure(path)
    if message.find("newer") != -1:
        return version_failure(path, trailing_number(message))
    return operational_failure("cannot use the store: " + message)


def trailing_number(message: String) -> Int:
    """The number a marker carries after its first word.

    `newer 7` yields 7; a message with no number yields 0.
    """
    var found = 0
    var digits = 0
    for c in message.codepoints():
        var code = Int(c)
        if code >= 48 and code <= 57:
            found = found * 10 + (code - 48)
            digits += 1
        elif digits > 0:
            break
    return found


# --------------------------------------------------------------- reading


struct Invocation(Movable):
    """One invocation row, as the store holds it."""

    var id: Int
    var ts: String
    var skill: String
    var parent: String
    var model: String
    var project: String
    var t3_thread: String
    var opencode_thread: String
    var worktree: String
    var machine: String
    var fix: String
    var resolved_at: String
    var origin_id: Int
    var problems: List[String]

    def __init__(out self):
        self.id = 0
        self.ts = ""
        self.skill = ""
        self.parent = ""
        self.model = ""
        self.project = ""
        self.t3_thread = ""
        self.opencode_thread = ""
        self.worktree = ""
        self.machine = ""
        self.fix = ""
        self.resolved_at = ""
        self.origin_id = 0
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


def sanitize(text: String) -> String:
    """Readable render: control characters become spaces.

    The reference's set — C0 minus tab, plus DEL. A newline becomes a
    space, so one problem stays one line and cannot inject a terminal
    escape.
    """
    var out = String("")
    for c in text.codepoints():
        var code = Int(c)
        if is_control(code):
            out += " "
        else:
            out += String(c)
    return out


def is_control(code: Int) -> Bool:
    """True when a code point is one the reference strips.

    C0 below 0x20 except tab, plus DEL. Tab is left alone: it is a
    character a person meant to type.
    """
    if code == 9:
        return False
    if code < 0x20:
        return True
    return code == 0x7F


def read_invocation(db: Database, id: Int) raises -> Optional[Invocation]:
    """Read one invocation row and its problems.

    The problems are read in ordinal order and sanitized on the way out,
    so one problem is one line whatever the writer stored.
    """
    var stmt = db.prepare(
        "SELECT id, ts, skill, parent, model, project, t3_thread,"
        " opencode_thread, worktree, machine, fix, resolved_at, origin_id"
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
    invocation.parent = row.value().text_val(3)
    invocation.model = row.value().text_val(4)
    invocation.project = row.value().text_val(5)
    invocation.t3_thread = row.value().text_val(6)
    invocation.opencode_thread = row.value().text_val(7)
    invocation.worktree = row.value().text_val(8)
    invocation.machine = row.value().text_val(9)
    invocation.fix = row.value().text_val(10)
    invocation.resolved_at = row.value().text_val(11)
    invocation.origin_id = row.value().int_val(12)

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


def write_invocation(
    path: String, mut row: Invocation, mut problems: List[String]
) raises -> Int:
    """Write one invocation and its problems, atomically.

    One transaction covers the invocation row and every problem row: a
    failed write leaves nothing behind. A BUSY/LOCKED failure is retried
    as a whole attempt inside the write budget, because a concurrent
    skill run holding the lock costs milliseconds, not the command.

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
) raises -> Int:
    """One write attempt: open, insert, insert, commit.

    The transaction guard rolls back when an insert fails, so a partial
    write is impossible. The invocation row is inserted first and its
    id is read back inside the same transaction.
    """
    var db = open_write(path)

    var tx = db.transaction()

    row.ts = local_timestamp(db)

    var stmt = db.prepare(
        "INSERT INTO invocations"
        " (ts, skill, parent, model, project, t3_thread,"
        " opencode_thread, worktree, machine, fix, resolved_at, origin_id)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    stmt.bind_text(1, row.ts)
    stmt.bind_text(2, row.skill)
    stmt.bind_text(3, row.parent)
    stmt.bind_text(4, row.model)
    stmt.bind_text(5, row.project)
    stmt.bind_text(6, row.t3_thread)
    stmt.bind_text(7, row.opencode_thread)
    stmt.bind_text(8, row.worktree)
    stmt.bind_text(9, row.machine)
    stmt.bind_text(10, row.fix)
    stmt.bind_text(11, row.resolved_at)
    stmt.bind_int(12, row.origin_id)
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

    tx.commit()
    return id
