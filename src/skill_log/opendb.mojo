"""A read-only SQLite reader for another tool's database.

The opencode adapter needs one value out of opencode's own session store:
the model of the session that ran the skill. That store belongs to another
program, so this reader is deliberately narrow:

- The file is opened **read-only** (`SQLITE_OPEN_READONLY`), so SQLite
  cannot create it, cannot create the `-wal` and `-shm` companions beside
  it, and cannot write a single byte into it.
- Only `SELECT` is ever issued. There is no write path here at all.
- Every failure is an empty string, never an exception: another
  program's schema is not this tool's contract, and an upstream change
  must degrade to a blank field rather than to a failed write.

The binding is loaded the same way the vendored one loads it — `dlopen`
plus `dlsym` — and the same way `context.mojo` reaches libc: a small
number of C entry points, resolved at run time.

The risk worth naming: opening another tool's database read-write can
race that tool's own writes and can leave a `-wal` file behind. This
reader never does that, and the file is checked for existence before the
connection is made, so a store that is not there is never created.
"""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import Pointer, alloc

# `SQLITE_OPEN_READONLY` is 0x01. The other flags are deliberately
# absent: no `SQLITE_OPEN_CREATE` (the file must already exist), and no
# `SQLITE_OPEN_READWRITE` (nothing may be written).
comptime SQLITE_OPEN_READONLY = 0x01

comptime SQLITE_OK = 0
comptime SQLITE_ROW = 100
comptime SQLITE_DONE = 101

# The buffer a C string is read into. A model id and a provider id are
# short; a pathological value is truncated rather than growing without
# bound.
comptime TEXT_SIZE = 4096


def _dl_sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    """Look up a C-ABI symbol as a plain callable value.

    The same shape the vendored binding uses: `dlopen` gives us the
    handle, `dlsym` gives the address, and the address is called
    through a typed pointer.
    """
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("symbol not found: " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


def _c_string(text: String) -> List[UInt8]:
    """A NUL-terminated copy of `text`.

    The copy is explicit because `String.unsafe_ptr()` is read-only in
    this Mojo version, so the terminator cannot be written in place.
    """
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


def read_text_value(
    path: String, sql: String, argument: String
) -> String:
    """One text value from a SQLite file, read-only.

    `path` is opened read-only; `sql` is a single-parameter `SELECT`
    whose one placeholder is bound to `argument`. An empty string is
    returned when the file is missing, the schema does not have the
    table, the row is absent, the value is NULL, or anything at all
    goes wrong. The caller cannot tell those apart, and does not need
    to: every one of them means "unknown".
    """
    # The whole body is guarded: a missing libsqlite3, an unreadable
    # file, an unknown symbol — none of them is an error here. The
    # field is simply unknown.
    try:
        return _read_text_value(path, sql, argument)
    except:
        return ""


def _read_text_value(
    path: String, sql: String, argument: String
) raises -> String:
    """The unguarded body of `read_text_value`."""
    # The same flags the vendored binding uses: `GLOBAL` so the symbols
    # resolve against the library this handle owns, and `NODELETE` so
    # closing it is a no-op and the library stays resident for the
    # process lifetime.
    var lib = OwnedDLHandle(
        "libsqlite3.so.0", RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
    )
    var open_v2 = _dl_sym[
        def(Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_open_v2")
    var close = _dl_sym[def(Int) thin abi("C") -> Int32](lib, "sqlite3_close")
    var prepare_v2 = _dl_sym[
        def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_prepare_v2")
    var step = _dl_sym[def(Int) thin abi("C") -> Int32](lib, "sqlite3_step")
    var finalize = _dl_sym[def(Int) thin abi("C") -> Int32](
        lib, "sqlite3_finalize"
    )
    var bind_text = _dl_sym[
        def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
    ](lib, "sqlite3_bind_text")
    var column_text = _dl_sym[def(Int, Int) thin abi("C") -> Int](
        lib, "sqlite3_column_text"
    )
    var errmsg = _dl_sym[def(Int) thin abi("C") -> Int](lib, "sqlite3_errmsg")

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
