"""The writer's context: when it happened, and on which machine."""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import alloc
from std.os import getenv

from sqlite.db import Database

from skill_log.ffi import dl_sym

comptime CLOCK_OVERRIDE = "SKILL_LOG_NOW"

comptime CLOCK_SQL = """\
SELECT
    strftime('%Y-%m-%dT%H:%M:%S','now','localtime'),
    CAST(strftime('%s','now','localtime') AS INTEGER)
        - CAST(strftime('%s','now') AS INTEGER)"""

comptime HOSTNAME_SIZE = 256


def format_offset(seconds: Int) -> String:
    """The UTC offset as `+HH:MM` or `-HH:MM`."""
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

    `SKILL_LOG_NOW`, when set, is the stamp: the test-only clock injection
    (SPEC §9) is consulted first and returned as written.
    """
    var pinned = getenv(CLOCK_OVERRIDE, "")
    if pinned != "":
        return pinned
    var stmt = db.prepare(CLOCK_SQL)
    var row = stmt.step()
    if row is None:
        return ""
    return row.value().text_val(0) + format_offset(row.value().int_val(1))


def preview_timestamp() raises -> String:
    """The writer's local wall clock, read without touching the store."""
    var db = Database(":memory:")
    return local_timestamp(db)


def hostname_unavailable() -> Error:
    """The failure for a machine whose hostname cannot be read."""
    return Error("cannot read this machine's hostname; name it with --machine")


def hostname() raises -> String:
    """This machine's hostname.

    A hostname that cannot be read is an error, not an empty string: the
    machine namespaces the store's markers, so a row without one is a row
    nothing can resolve.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var gethostname = dl_sym[def(Int, Int) thin abi("C") -> Int](
            lib, "gethostname"
        )
        var buffer = alloc[c_char](HOSTNAME_SIZE)
        var rc = gethostname(Int(buffer), HOSTNAME_SIZE)
        if rc != 0:
            raise hostname_unavailable()
        var text = String(
            StringSlice(unsafe_from_utf8=CStringSpan(unsafe_from_ptr=buffer))
        )
        if text == "":
            raise hostname_unavailable()
        return text
    except:
        raise hostname_unavailable()
