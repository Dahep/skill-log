"""The store: where it lives, what it holds, and when it is refused."""

from std.ffi import OwnedDLHandle, RTLD
from std.os import makedirs
from std.pathlib import Path
from std.time import monotonic, sleep

from sqlite.db import Database, Row
from skill_log.context import local_timestamp
from skill_log.errors import Failure, operational_failure
from skill_log.ffi import dl_sym
from skill_log.markers import marker_text
from skill_log.opendb import read_only_database
from skill_log.settings import expand_home, resolve_db
from skill_log.text import sanitize

comptime SCHEMA_VERSION = 1

# The column list is the schema: the DDL, the allow-list, the SELECT lists
# and the JSON key order are all built from it.
struct ColumnDef:
    """One column: its name, its SQL type, and its default."""

    var name: String
    var sql_type: String
    var default: String
    var not_null: Bool

    def __init__(
        out self,
        name: String,
        sql_type: String = "TEXT",
        default: String = "",
        not_null: Bool = False,
    ):
        self.name = name
        self.sql_type = sql_type
        self.default = default
        self.not_null = not_null

    def ddl(self) -> String:
        """The column as the `CREATE TABLE` spells it."""
        var out = self.name + " " + self.sql_type
        if self.not_null:
            out += " NOT NULL"
        if self.default != "":
            out += " DEFAULT " + self.default
        return out


def invocation_columns() -> List[ColumnDef]:
    """The invocations table's columns, in the schema's own order."""
    var columns = List[ColumnDef]()
    columns.append(ColumnDef("id", "INTEGER PRIMARY KEY AUTOINCREMENT"))
    columns.append(ColumnDef("ts", "TEXT", "", True))
    columns.append(ColumnDef("skill", "TEXT", "", True))
    columns.append(ColumnDef("harness", "TEXT", "''", True))
    columns.append(ColumnDef("session", "TEXT", "''", True))
    columns.append(ColumnDef("parent", "TEXT", "''", True))
    columns.append(ColumnDef("model", "TEXT", "''", True))
    columns.append(ColumnDef("repo", "TEXT", "''", True))
    columns.append(ColumnDef("worktree", "TEXT", "''", True))
    columns.append(ColumnDef("project", "TEXT", "''", True))
    columns.append(ColumnDef("t3_thread", "TEXT", "''", True))
    columns.append(ColumnDef("machine", "TEXT", "''", True))
    columns.append(ColumnDef("fix", "TEXT", "''", True))
    columns.append(ColumnDef("resolved_at", "TEXT", "''", True))
    return columns^


def invocation_ddl() -> String:
    """The `CREATE TABLE` for the invocations table, built from the column list."""
    var columns = invocation_columns()
    var body = String("")
    for i in range(len(columns)):
        if i > 0:
            body += ",\n"
        body += "    " + columns[i].ddl()
    return "CREATE TABLE IF NOT EXISTS invocations (\n" + body + "\n)"


comptime PROBLEM_DDL = """\
CREATE TABLE IF NOT EXISTS problems (
    invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    problem TEXT NOT NULL,
    PRIMARY KEY (invocation_id, ordinal)
)"""

def store_column_names() -> List[String]:
    """Every invocations column the 1.0 schema has."""
    var names = List[String]()
    var columns = invocation_columns()
    for i in range(len(columns)):
        names.append(columns[i].name)
    return names^


def invocation_select_list() -> String:
    """The column list a `SELECT` of an invocation row names."""
    var names = List[String]()
    var columns = invocation_columns()
    for i in range(len(columns)):
        names.append(columns[i].name)
    return ", ".join(names)


def invocation_insert_sql() -> String:
    """The `INSERT INTO invocations` statement, built from the columns."""
    var names = List[String]()
    var columns = invocation_columns()
    for i in range(len(columns)):
        if columns[i].name == "id":
            continue
        names.append(columns[i].name)
    var marks = List[String]()
    for _ in range(len(names)):
        marks.append("?")
    return (
        "INSERT INTO invocations (" + ", ".join(names) + ") VALUES ("
        + ", ".join(marks) + ")"
    )

# The write budget: a whole attempt is retried, because a lock is retryable
# and a refusal is not.
comptime WRITE_BUDGET_SECONDS = 5.0
comptime WRITE_RETRY_SLEEP = 0.1
comptime WRITE_CONNECT_TIMEOUT = 2

comptime READ_BUSY_TIMEOUT = 5000
comptime WRITE_BUSY_TIMEOUT = WRITE_CONNECT_TIMEOUT * 1000



def parent_dir(path: String) -> String:
    """The directory that holds `path`."""
    var cut = path.rfind("/")
    if cut <= 0:
        return ""
    return String(path[byte=0:cut])




def is_corruption(message: String) -> Bool:
    """True when a SQLite error means the file is not a usable store."""
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


def locked_failure(path: String) -> Failure:
    """The named failure for a store another writer is holding."""
    return operational_failure(
        "locked store: " + path + " is held by another writer"
    )


def read_only_failure(path: String) -> Failure:
    """The named failure for a store file the writer may not write."""
    return operational_failure(
        "read-only store: " + path + " cannot be written to"
    )


def is_read_only(message: String) -> Bool:
    """True when a SQLite error means the file could not be written."""
    var text = message.lower()
    return (
        text.find("readonly database") != -1
        or text.find("read-only database") != -1
    )


def unopenable_failure(path: String) -> Failure:
    """The named failure for a store file that cannot be opened at all."""
    return operational_failure(
        "unusable store path: " + path + " cannot be opened for writing"
    )


def is_unopenable(message: String) -> Bool:
    """True when a SQLite error means the store file could not be opened."""
    return message.find("sqlite3_open(") != -1 and message.find("rc=14") != -1


def strip_path(message: String, path: String) -> String:
    """`message` with the store's own path removed.

    The binding puts the path it was given into its own wording, and a path
    can contain any word the taxonomy uses, so the classification is made
    on what the binding appended *after* the path, never on the path.
    """
    if path == "":
        return message
    var out = strip_field(message, "'" + path + "'")
    return strip_field(out, ": " + path)


def strip_field(message: String, field: String) -> String:
    """`message` with every occurrence of `field` removed."""
    if field == "":
        return message
    var at = message.find(field)
    if at < 0:
        return message
    var out = String("")
    var start = 0
    while at >= 0:
        out += String(message[byte=start:at])
        start = at + field.byte_length()
        at = message.find(field, start)
    out += String(message[byte=start:])
    return out


def read_failure(path: String, message: String) -> Failure:
    """The named failure for a SQLite error on the read path."""
    var detail = strip_path(message, path)
    if is_corruption(detail):
        return damaged_failure(path)
    if is_busy(detail):
        return locked_failure(path)
    if is_unopenable(detail):
        return unopenable_failure(path)
    return operational_failure("cannot read the store: " + path + ": " + message)


def write_failure(path: String, message: String) -> Failure:
    """The named failure for a SQLite error on the write path.

    The same taxonomy the read path has (SPEC §3). The named ones do not
    carry SQLite's wording, so a caller never has to read it to learn what
    happened.
    """
    var detail = strip_path(message, path)
    if is_corruption(detail):
        return damaged_failure(path)
    if is_busy(detail):
        return locked_failure(path)
    if is_read_only(detail):
        return read_only_failure(path)
    if is_unopenable(detail):
        return unopenable_failure(path)
    return operational_failure(
        "cannot write the store: " + path + ": " + message
    )


def raise_write_failure(path: String, message: String) raises:
    """Raise the named failure for a write error."""
    var failure = write_failure(path, message)
    raise Error(failure.message)


def older_failure(path: String) -> Failure:
    """The named failure for a store written by the pre-ADR-0002 schema."""
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


# The refusal kinds: a lock is deliberately not one of them, because a refusal
# is final and a lock is retryable.
comptime REFUSAL_NONE = 0
comptime REFUSAL_DAMAGED = 1
comptime REFUSAL_FOREIGN = 2
comptime REFUSAL_OLDER = 3
comptime REFUSAL_NEWER = 4


struct Refusal(Movable):
    """A store that was refused, and why.

    The kind is a value rather than a word inside a message: a path the
    caller named can contain any word at all, so a scheme that re-derived
    the kind from the message text would let the path decide the refusal.
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
        """The named failure for this refusal."""
        if self.kind == REFUSAL_DAMAGED:
            return damaged_failure(self.path)
        if self.kind == REFUSAL_FOREIGN:
            return foreign_failure(self.path)
        if self.kind == REFUSAL_OLDER:
            return older_failure(self.path)
        if self.kind == REFUSAL_NEWER:
            return version_failure(self.path, self.found)
        return operational_failure("cannot use the store: " + self.path)




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
    """The 1.0 columns the invocations table lacks."""
    return missing_columns(db, "invocations", store_column_names())


def store_problem_column_names() -> List[String]:
    """Every problems column the 1.0 schema has."""
    var names = List[String]()
    names.append("invocation_id")
    names.append("ordinal")
    names.append("problem")
    return names^


def missing_problem_columns(db: Database) raises -> List[String]:
    """The 1.0 columns the problems table lacks."""
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
    """True when this is a skill-log store written before ADR-0002."""
    if not has_store_tables(db):
        return False
    return len(missing_store_columns(db)) > 0


def stamp_version(db: Database) raises:
    """Write this binary's schema version onto the store."""
    db.execute("PRAGMA user_version=" + String(SCHEMA_VERSION))


comptime SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006


def disable_close_checkpoint(db: Database):
    """Ask SQLite not to checkpoint this store when the read closes."""
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
    """The connection settings a read carries."""
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=" + String(busy_timeout))


def apply_write_pragmas(db: Database, busy_timeout: Int) raises:
    """The connection settings a write carries."""
    db.execute("PRAGMA journal_mode=WAL")
    apply_read_pragmas(db, busy_timeout)




def user_table_count(db: Database) raises -> Int:
    """How many ordinary tables the file holds."""
    var stmt = db.prepare(
        "SELECT count(*) FROM sqlite_master"
        " WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    )
    var row = stmt.step()
    if row is None:
        return 0
    return row.value().int_val(0)


struct StoreOpen(Movable):
    """What opening a store produced: the connection, or the refusal."""

    var db: Optional[Database]
    var refusal: Refusal

    def __init__(out self):
        self.db = None
        self.refusal = Refusal()


def schema_refusal(db: Database, existed: Bool, path: String) raises -> Refusal:
    """What, if anything, is wrong with this file's schema."""
    try:
        if is_older_store(db):
            return Refusal(REFUSAL_OLDER, "", 0)

        var ours = is_skill_log_store(db)
        if not ours and existed and (
            user_table_count(db) > 0 or user_version(db) != 0
        ):
            ours = is_skill_log_store(db)
            if not ours:
                return Refusal(REFUSAL_FOREIGN, "", 0)

        if ours:
            var found = user_version(db)
            if found > SCHEMA_VERSION:
                return Refusal(REFUSAL_NEWER, "", found)
        return Refusal()
    except e:
        if is_corruption(strip_path(String(e), path)):
            return Refusal(REFUSAL_DAMAGED, "", 0)
        raise


def open_read(path: String) raises -> StoreOpen:
    """Open an existing store for reading.

    `db` is `None` when the file does not exist: a read never creates the
    state directory, the file, or an empty database. The vendored binding
    opens read-write, so the read path opens the store read-only instead —
    a file that is not there is a failure and never a new file.
    """
    var opened = StoreOpen()
    if not Path(path).is_file():
        return opened^

    var db = read_only_database(path)

    disable_close_checkpoint(db)

    db.execute("PRAGMA busy_timeout=" + String(READ_BUSY_TIMEOUT))

    var refusal = schema_refusal(db, True, path)
    if refusal.refused():
        refusal.path = path
        opened.refusal = refusal^
        return opened^

    apply_read_pragmas(db, READ_BUSY_TIMEOUT)
    db.execute("PRAGMA query_only=ON")
    opened.db = db^
    return opened^


def open_write(path: String) raises -> StoreOpen:
    """Open the store for writing, creating it when it does not exist."""
    var opened = StoreOpen()
    var existed = Path(path).is_file()

    var dir = parent_dir(path)
    if dir != "":
        try:
            makedirs(dir, exist_ok=True)
        except e:
            raise Error("cannot create the store's directory: " + String(e))

    var db = Database(path)

    db.execute("PRAGMA busy_timeout=" + String(WRITE_BUSY_TIMEOUT))

    var refusal = schema_refusal(db, existed, path)
    if refusal.refused():
        refusal.path = path
        opened.refusal = refusal^
        return opened^

    if not is_skill_log_store(db):
        try:
            var tx = db.transaction()
            db.execute(invocation_ddl())
            db.execute(PROBLEM_DDL)
            tx.commit()
        except e:
            raise Error("cannot create the store's schema: " + String(e))

    apply_write_pragmas(db, WRITE_BUSY_TIMEOUT)

    stamp_version(db)
    opened.db = db^
    return opened^


struct Verify(Movable):
    """What `verify` found: a usable store, no file, or a named refusal."""

    var absent: Bool
    var refusal: Refusal

    def __init__(out self):
        self.absent = False
        self.refusal = Refusal()

    def ok(self) -> Bool:
        """True when the file is a usable 1.0 skill-log store."""
        return not self.absent and not self.refusal.refused()


def verify(path: String) raises -> Verify:
    """The store's verdict under the `verify` policy."""
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




struct Invocation(Movable):
    """One invocation row, as the store holds it."""

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
        """The row's marker: `machine#id`."""
        if self.id == 0:
            return ""
        return marker_text(self.machine, self.id)

    def text_column(self, column: String) -> String:
        """One text column's value, by the column's name."""
        if column == "ts":
            return self.ts
        if column == "skill":
            return self.skill
        if column == "harness":
            return self.harness
        if column == "session":
            return self.session
        if column == "parent":
            return self.parent
        if column == "model":
            return self.model
        if column == "repo":
            return self.repo
        if column == "worktree":
            return self.worktree
        if column == "project":
            return self.project
        if column == "t3_thread":
            return self.t3_thread
        if column == "machine":
            return self.machine
        if column == "fix":
            return self.fix
        if column == "resolved_at":
            return self.resolved_at
        return ""

    def set_text_column(mut self, column: String, value: String):
        """One text column's value, by the column's name."""
        if column == "ts":
            self.ts = value
        elif column == "skill":
            self.skill = value
        elif column == "harness":
            self.harness = value
        elif column == "session":
            self.session = value
        elif column == "parent":
            self.parent = value
        elif column == "model":
            self.model = value
        elif column == "repo":
            self.repo = value
        elif column == "worktree":
            self.worktree = value
        elif column == "project":
            self.project = value
        elif column == "t3_thread":
            self.t3_thread = value
        elif column == "machine":
            self.machine = value
        elif column == "fix":
            self.fix = value
        elif column == "resolved_at":
            self.resolved_at = value


def invocation_text_columns() -> List[ColumnDef]:
    """Every text column of the invocations table, in order."""
    var columns = List[ColumnDef]()
    var all = invocation_columns()
    for i in range(len(all)):
        if all[i].sql_type == "TEXT":
            columns.append(all[i])
    return columns^


def read_invocation_row(row: Row) raises -> Invocation:
    """One invocation row, read through the column list."""
    var invocation = Invocation()
    var columns = invocation_columns()
    for i in range(len(columns)):
        if columns[i].name == "id":
            invocation.id = row.int_val(i)
        else:
            invocation.set_text_column(columns[i].name, row.text_val(i))
    return invocation^


def read_invocation(db: Database, id: Int) raises -> Optional[Invocation]:
    """Read one invocation row and its problems."""
    var stmt = db.prepare(
        "SELECT " + invocation_select_list()
        + " FROM invocations WHERE id = ?"
    )
    stmt.bind_int(1, id)
    var row = stmt.step()
    if row is None:
        return None

    var invocation = read_invocation_row(row.value())

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


comptime DEFAULT_LIMIT = 20

struct Filters(Movable):
    """What one read of the store selects."""

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
    """The `WHERE` clause the filters ask for, without the keyword."""
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
        marks.append(filters.run)
        marks.append(filters.run)
        marks.append(filters.run)
    return marks^


def read_invocations(db: Database, filters: Filters) raises -> List[Invocation]:
    """Read the invocation rows the filters select, newest first."""
    var clause = filter_clause(filters)
    var marks = filter_parameters(filters)

    var limit = " LIMIT ?"
    if filters.limit <= 0:
        limit = ""

    var stmt = db.prepare(
        "SELECT " + invocation_select_list()
        + " FROM invocations" + clause
        + " ORDER BY datetime(ts) DESC, id DESC" + limit
    )

    for i in range(len(marks)):
        stmt.bind_text(i + 1, marks[i])
    if filters.limit > 0:
        stmt.bind_int(len(marks) + 1, filters.limit)

    var rows = List[Invocation]()
    while True:
        var row = stmt.step()
        if row is None:
            break

        var invocation = read_invocation_row(row.value())

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




def group_columns() -> List[String]:
    """The columns a count may be grouped by, default first."""
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
    """True when `name` is one of the columns `stats` may group by."""
    var columns = group_columns()
    for i in range(len(columns)):
        if columns[i] == name:
            return True
    return False


struct GroupCount(Movable):
    """One line of the stats table: a group's key and its four counts.

    `with_problems` counts invocations that have at least one problem, and
    `problems` counts problem rows. They differ by design: the rate's
    denominator is invocations, so a run with two findings is one run and
    two problems.
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

    `COUNT(DISTINCT i.id)` is the denominator and the only honest count: the
    LEFT JOIN produces one line per problem, so `COUNT(*)` would count
    problems and `COUNT(DISTINCT i.id)` counts runs.
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




def is_busy(message: String) -> Bool:
    """True when a SQLite error means the store was busy or locked."""
    var text = message.lower()
    return text.find("locked") != -1 or text.find("busy") != -1


def now_seconds() -> Float64:
    """A monotonic clock reading in seconds, for the write budget."""
    return Float64(monotonic()) / 1_000_000_000.0


struct WriteResult(Movable):
    """What a write produced: the new row's id, or the refusal."""

    var id: Int
    var refusal: Refusal

    def __init__(out self):
        self.id = 0
        self.refusal = Refusal()


struct BusyBudget:
    """The wall-clock budget a write spends on a lock."""

    var deadline: Float64

    def __init__(out self):
        self.deadline = now_seconds() + WRITE_BUDGET_SECONDS

    def remaining(self) -> Float64:
        """The seconds left in the budget."""
        return self.deadline - now_seconds()

    def retry(self) -> Bool:
        """True when there is budget left for another attempt."""
        var left = self.remaining()
        if left <= 0:
            return False
        sleep(min(Float64(WRITE_RETRY_SLEEP), left))
        return True


def write_invocation(
    path: String, mut row: Invocation, mut problems: List[String]
) raises -> WriteResult:
    """Write one invocation and its problems, atomically.

    One transaction covers the invocation row and every problem row: a
    failed write leaves nothing behind. A BUSY/LOCKED failure is retried as
    a whole attempt inside the write budget, because a concurrent skill run
    holding the lock costs milliseconds, not the command.
    """
    var result = WriteResult()
    var budget = BusyBudget()

    while True:
        try:
            result = write_attempt(path, row, problems)
            return result^
        except e:
            var message = String(e)
            var detail = strip_path(message, path)
            if not is_busy(detail):
                raise_write_failure(path, message)
            if not budget.retry():
                raise_write_failure(path, message)


def write_attempt(
    path: String, mut row: Invocation, mut problems: List[String]
) raises -> WriteResult:
    """One write attempt: open, insert, insert, commit."""
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

    var stmt = db.prepare(invocation_insert_sql())
    var columns = invocation_columns()
    for i in range(len(columns)):
        if columns[i].name == "id":
            continue
        if columns[i].name == "ts":
            stmt.bind_text(i, row.ts)
        else:
            stmt.bind_text(i, row.text_column(columns[i].name))
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
        # A statement that reached SQLITE_DONE must be reset before it is bound again.
        problem_stmt.reset()
        problem_stmt.bind_int(1, id)
        problem_stmt.bind_int(2, i + 1)
        problem_stmt.bind_text(3, problems[i])
        _ = problem_stmt.step()

    result.id = id
    tx.commit()
    return result^




struct ResolvedRow(Movable):
    """One row's resolution after `resolve` touched it (or looked at it)."""

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
    """Stamp one row with the commit that carries its fix."""
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
        result.resolved_at = row.value().resolved_at
        return result^

    if dry_run:
        result.resolved_at = local_timestamp(db)
        result.changed = True
        return result^

    var budget = BusyBudget()
    while True:
        try:
            return stamp_attempt(path, id, fix)
        except e:
            var message = String(e)
            var detail = strip_path(message, path)
            if not is_busy(detail):
                raise_write_failure(path, message)
            if not budget.retry():
                raise_write_failure(path, message)


def stamp_attempt(path: String, id: Int, fix: String) raises -> ResolvedRow:
    """One write attempt: open, re-read inside the transaction, stamp."""
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
        _ = tx^
        return result^

    result.found = True
    result.skill = row.value().text_val(0)
    result.machine = row.value().text_val(1)
    result.fix = fix

    if row.value().text_val(2) == fix:
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




comptime SKIP_UNKNOWN_ID = "unknown_id"
comptime SKIP_FOREIGN = "foreign"
comptime SKIP_LOGGED_AFTER = "logged_after_commit"


struct Located(Movable):
    """One marker the scan found, and the commit and time it came from."""

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
        return marker_text(self.machine, self.id)


struct MergedSkip(Movable):
    """One marker a scan could not stamp, and the reason it was skipped."""

    var row: String
    var reason: String

    def __init__(out self, row: String = "", reason: String = ""):
        self.row = row
        self.reason = reason


struct Stamped(Movable):
    """One row a merged scan stamped: its marker and what stamped it."""

    var marker: String
    var commit: String
    var machine: String
    var id: Int

    def __init__(
        out self,
        marker: String = "",
        commit: String = "",
        machine: String = "",
        id: Int = 0,
    ):
        self.marker = marker
        self.commit = commit
        self.machine = machine
        self.id = id


struct MergedResult(Movable):
    """What a merged scan produced: the rows it stamped, kept, and skipped."""

    var stamped: List[Stamped]
    var unchanged: List[String]
    var skipped: List[MergedSkip]
    var refusal: Refusal

    def __init__(out self):
        self.stamped = List[Stamped]()
        self.unchanged = List[String]()
        self.skipped = List[MergedSkip]()
        self.refusal = Refusal()


struct ResolutionRow(Movable):
    """The columns a merged scan needs from one invocation row."""

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
        "SELECT id, machine, fix,"
        " COALESCE(CAST(strftime('%s', ts) AS INTEGER), 0)"
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
    """The index of the row a marker names, or -1."""
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

    Pure: no git, no clock, no store. The newest marker wins, because the
    scan walks commits newest first. A row stamped with the *same* commit is
    unchanged; a row stamped with a *different* commit is restamped. A marker
    whose machine is not this host's spelling is foreign and is never stamped
    (SPEC §2).
    """
    var result = MergedResult()
    for i in range(len(located)):
        var marker = located[i].text()
        if located[i].machine != local_host:
            var foreign = MergedSkip(marker, SKIP_FOREIGN)
            result.skipped.append(foreign^)
            continue
        var index = merged_row_index(
            rows, located[i].machine, located[i].id, local_host
        )
        if index == -1:
            var missing = MergedSkip(marker, SKIP_UNKNOWN_ID)
            result.skipped.append(missing^)
            continue
        if rows[index].fix != "" and rows[index].fix == located[i].commit:
            result.unchanged.append(marker)
            continue
        if rows[index].logged > located[i].epoch:
            var later = MergedSkip(marker, SKIP_LOGGED_AFTER)
            result.skipped.append(later^)
            continue
        result.stamped.append(
            Stamped(marker, located[i].commit, located[i].machine, located[i].id)
        )
    return result^


def resolve_merged_rows(
    path: String,
    located: List[Located],
    local_host: String,
    dry_run: Bool,
) raises -> MergedResult:
    """Apply: stamp every row the scanned markers name."""
    var result = MergedResult()
    if len(located) == 0:
        return result^
    if not Path(path).is_file():
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

    var budget = BusyBudget()
    while True:
        try:
            return merged_write_attempt(path, located, local_host)
        except e:
            var message = String(e)
            var detail = strip_path(message, path)
            if not is_busy(detail):
                raise_write_failure(path, message)
            if not budget.retry():
                raise_write_failure(path, message)


def merged_write_attempt(
    path: String, located: List[Located], local_host: String
) raises -> MergedResult:
    """The writer `apply`: open, re-read, re-decide, stamp, commit."""
    var result = MergedResult()
    if not Path(path).is_file():
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
        _ = tx^
        return resolved^
    # One prepared statement, reset per row: preparing inside the loop leaves the
    # earlier one unfinalized, and the COMMIT then fails with SQLITE_MISUSE.
    var update = db.prepare(
        "UPDATE invocations SET fix = ?, resolved_at = ? WHERE id = ?"
    )
    for i in range(len(resolved.stamped)):
        var row_index = merged_row_index(
            rows,
            resolved.stamped[i].machine,
            resolved.stamped[i].id,
            local_host,
        )
        if row_index == -1:
            continue
        update.reset()
        update.bind_text(1, resolved.stamped[i].commit)
        update.bind_text(2, stamp)
        update.bind_int(3, rows[row_index].id)
        _ = update.step()
    tx.commit()
    return resolved^
