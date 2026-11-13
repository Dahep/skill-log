"""Opening a store: read-write, or read-only."""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import Pointer

from sqlite.db import Database

from skill_log.ffi import dl_sym

comptime SQLITE_OPEN_READONLY = 0x01

comptime SQLITE_OK = 0
comptime SQLITE_ROW = 100
comptime SQLITE_DONE = 101

comptime TEXT_SIZE = 4096


def _c_string(text: String) -> List[UInt8]:
    """A NUL-terminated copy of `text`."""
    var n = text.byte_length()
    var src = text.unsafe_ptr()
    var buf = List[UInt8](capacity=n + 1)
    for i in range(n):
        buf.append(src[unsafe_offset=i])
    buf.append(0)
    return buf^


def _ptr_to_string(addr: Int) -> String:
    """Copy a NUL-terminated C string at `addr` into an owned String."""
    if addr == 0:
        return String("")
    var p = Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr)
    return String(StringSlice(unsafe_from_utf8=CStringSpan(unsafe_from_ptr=p)))


def read_only_database(path: String) raises -> Database:
    """A `Database` opened read-only, or a failure naming the path.

    The vendored binding opens read-write, so a read-only open is reached
    through SQLite's own flags: a file that is not there is a failure and
    never a new file.
    """
    var lib = OwnedDLHandle(
        "libsqlite3.so.0", RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
    )
    var open_v2 = dl_sym[def(Int, Int, Int, Int) thin abi("C") -> Int32](
        lib, "sqlite3_open_v2"
    )
    var close = dl_sym[def(Int) thin abi("C") -> Int32](lib, "sqlite3_close")

    var db_out = List[Int](capacity=1)
    db_out.append(0)
    var path_buf = _c_string(path)
    var rc = open_v2(
        Int(path_buf.unsafe_ptr()),
        Int(db_out.unsafe_ptr()),
        SQLITE_OPEN_READONLY,
        Int(0),
    )
    _ = path_buf^
    if Int(rc) != SQLITE_OK:
        raise Error("cannot open '" + path + "' read-only")

    var db = Database(":memory:")
    _ = close(db._handle)
    db._handle = db_out[0]
    return db^


def read_text_value(
    path: String, sql: String, argument: String
) -> String:
    """One text value from a SQLite file, read-only."""
    try:
        return _read_text_value(path, sql, argument)
    except:
        return ""


def _read_text_value(
    path: String, sql: String, argument: String
) raises -> String:
    """The unguarded body of `read_text_value`."""
    var lib = OwnedDLHandle(
        "libsqlite3.so.0", RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
    )
    var open_v2 = dl_sym[
        def(Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_open_v2")
    var close = dl_sym[def(Int) thin abi("C") -> Int32](lib, "sqlite3_close")
    var prepare_v2 = dl_sym[
        def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_prepare_v2")
    var step = dl_sym[def(Int) thin abi("C") -> Int32](lib, "sqlite3_step")
    var finalize = dl_sym[def(Int) thin abi("C") -> Int32](
        lib, "sqlite3_finalize"
    )
    var bind_text = dl_sym[
        def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_bind_text")
    var column_text = dl_sym[def(Int, Int) thin abi("C") -> Int](
        lib, "sqlite3_column_text"
    )

    var db_out = List[Int](capacity=1)
    db_out.append(0)

    var path_buf = _c_string(path)
    var rc = open_v2(
        Int(path_buf.unsafe_ptr()),
        Int(db_out.unsafe_ptr()),
        SQLITE_OPEN_READONLY,
        Int(0),
    )
    _ = path_buf^
    if Int(rc) != SQLITE_OK:
        return ""

    var db = db_out[0]

    var sql_buf = _c_string(sql)
    var stmt_out = List[Int](capacity=1)
    stmt_out.append(0)
    var sql_len = Int(sql.byte_length())
    var rc2 = prepare_v2(
        db,
        Int(sql_buf.unsafe_ptr()),
        sql_len,
        Int(stmt_out.unsafe_ptr()),
        Int(0),
    )
    _ = sql_buf^
    if Int(rc2) != SQLITE_OK:
        _ = close(db)
        return ""

    var stmt = stmt_out[0]

    var arg_buf = _c_string(argument)
    var rc3 = bind_text(
        stmt,
        Int(1),
        Int(arg_buf.unsafe_ptr()),
        Int(argument.byte_length()),
        Int(-1),
    )
    _ = arg_buf^
    if Int(rc3) != SQLITE_OK:
        _ = finalize(stmt)
        _ = close(db)
        return ""

    var result = String("")
    var rc4 = step(stmt)
    if Int(rc4) == SQLITE_ROW:
        var addr = column_text(stmt, Int(0))
        result = _ptr_to_string(addr)

    _ = finalize(stmt)
    _ = close(db)
    return result
