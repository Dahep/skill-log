"""Read-only access to a SQLite file."""

from sqlite.db import Database
from sqlite.ffi import SQLITE_OPEN_READONLY


def read_only_database(path: String) raises -> Database:
    """A `Database` opened read-only; a missing file fails instead of being created."""
    return Database(path, flags=SQLITE_OPEN_READONLY)


def read_text_value(path: String, sql: String, argument: String) -> String:
    """One text value from a SQLite file, read-only, or ""."""
    try:
        return _read_text_value(path, sql, argument)
    except:
        return ""


def _read_text_value(path: String, sql: String, argument: String) raises -> String:
    var db = Database(path, flags=SQLITE_OPEN_READONLY)
    var stmt = db.prepare(sql)
    stmt.bind_text(1, argument)
    var row = stmt.step()
    if row is None:
        return ""
    return row.value().text_val(0)
