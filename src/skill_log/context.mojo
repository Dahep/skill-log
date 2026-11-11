"""The writer's context: when it happened and where.

Two facts a row carries that the tool cannot be told: the invocation's
timestamp and the machine's hostname. Both are read from the running
machine, never from a flag, in this ticket: the other context columns
stay at their schema defaults until a later ticket fills them.

The timestamp is ISO 8601 with the writer's own offset, to the second —
the same shape the Python reference's
`datetime.now().astimezone().isoformat(timespec="seconds")` produced.

It is computed in SQLite rather than through libc: the vendored binding
already carries a correct clock, and reaching `localtime_r` through
Mojo's C ABI is not safe on this toolchain. The two values SQLite gives
are the local wall clock and the offset in seconds; the offset is
formatted here.

The hostname comes from libc's `gethostname`, reached the same way the
vendored binding reaches SQLite: `dlopen` plus `dlsym`. That call is
safe — it touches no signal state.
"""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import Pointer, alloc

from sqlite.db import Database

# The query that yields the writer's local wall clock and the offset in
# seconds, in one row.
#
# `unixepoch('now','localtime')` is the current instant read in local
# time and then read back as if it were UTC, so the difference between
# it and `unixepoch('now')` is the offset: negative west of Greenwich,
# positive east of it.
comptime CLOCK_SQL = """\
SELECT
    strftime('%Y-%m-%dT%H:%M:%S','now','localtime'),
    unixepoch('now','localtime') - unixepoch('now')"""

# The hostname buffer. A hostname longer than this is truncated, which
# POSIX allows and no real machine reaches.
comptime HOSTNAME_SIZE = 256


def format_offset(seconds: Int) -> String:
    """The UTC offset as `+HH:MM` or `-HH:MM`.

    The sign is the sign of the offset, the hours and minutes are its
    absolute parts, and the minutes carry the half-hour offsets some
    zones use.
    """
    var sign = "+"
    if seconds < 0:
        sign = "-"
    var absolute = seconds
    if absolute < 0:
        absolute = -absolute
    var hours = absolute // 3600
    var minutes = (absolute % 3600) // 60
    return sign + two_digits(hours) + ":" + two_digits(minutes)


def two_digits(value: Int) -> String:
    """A number below 100 as two digits."""
    if value < 10:
        return "0" + String(value)
    return String(value)


def local_timestamp(db: Database) raises -> String:
    """The writer's local wall clock as ISO 8601 with its offset.

    `2026-11-11T17:04:36-03:00` is one such stamp.
    """
    var stmt = db.prepare(CLOCK_SQL)
    var row = stmt.step()
    if row is None:
        return ""
    return row.value().text_val(0) + format_offset(row.value().int_val(1))


def preview_timestamp() raises -> String:
    """The writer's local wall clock, read without touching the store.

    A `--dry-run` preview must write nothing, so the clock is read
    through an in-memory database: the clock lives in the SQLite
    library, not in the file.
    """
    var db = Database(":memory:")
    return local_timestamp(db)


def _dl_sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    """Look up a C-ABI symbol as a plain callable value.

    The same shape the vendored binding uses: `dlopen` gave us the
    handle, `dlsym` gives the address, and the address is called
    through a typed pointer.
    """
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("symbol not found: " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


def hostname() raises -> String:
    """This machine's hostname.

    An empty string when it cannot be read: the machine name is context,
    not the row's subject, and a missing hostname must not fail the
    write.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var gethostname = _dl_sym[def(Int, Int) thin abi("C") -> Int](
            lib, "gethostname"
        )
        var buffer = alloc[c_char](HOSTNAME_SIZE)
        var rc = gethostname(Int(buffer), HOSTNAME_SIZE)
        if rc != 0:
            return ""
        var text = String(
            StringSlice(unsafe_from_utf8=CStringSpan(unsafe_from_ptr=buffer))
        )
        return text
    except:
        return ""
