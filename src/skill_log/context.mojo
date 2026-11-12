"""The writer's context: when it happened, and on which machine.

Two facts a row carries that neither a flag nor an adapter may invent: the
invocation's timestamp and the machine's hostname. Both are read from the
running machine. Every other context column belongs to the caller or to an
adapter (`adapters.mojo`), and the arguments that carry them belong to
`add.mojo`.

The timestamp is ISO 8601 with the writer's own offset, to the second —
the same shape the Python reference's
`datetime.now().astimezone().isoformat(timespec="seconds")` produced.

It is computed in SQLite rather than through libc: the vendored binding
already carries a correct clock, and reaching `localtime_r` through
Mojo's C ABI is not safe on this toolchain. The two values SQLite gives
are the local wall clock and the offset in seconds; the offset is
formatted here.

The hostname comes from libc's `gethostname`, reached through the same
`dlopen` seam the vendored binding uses (`ffi.mojo`). Unlike every other
context field, an unreadable hostname is an error rather than a blank: the
machine namespaces the store's markers, so a row without one cannot be
named from outside.
"""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import alloc
from std.os import getenv

from sqlite.db import Database

from skill_log.ffi import dl_sym

# The one clock injection (SPEC §9): a test-only stamp that fixes the
# writer's clock. It is read before SQLite's clock, so a case can prove
# the time guard through the CLI instead of writing the store directly.
comptime CLOCK_OVERRIDE = "SKILL_LOG_NOW"

# The query that yields the writer's local wall clock and the offset in
# seconds, in one row.
#
# `strftime('%s','now','localtime')` is the current instant read in local
# time and then read back as if it were UTC, so the difference between
# it and `strftime('%s','now')` is the offset: negative west of
# Greenwich, positive east of it.
#
# The epoch seconds come from `strftime('%s', ...)`, not from SQLite's
# `unixepoch()`: `unixepoch` was added in SQLite 3.38 and the release
# bundles the pinned 3.37, where it does not exist. `strftime('%s')` is
# in every SQLite that has `strftime` at all, and it answers the same
# question.
comptime CLOCK_SQL = """\
SELECT
    strftime('%Y-%m-%dT%H:%M:%S','now','localtime'),
    CAST(strftime('%s','now','localtime') AS INTEGER)
        - CAST(strftime('%s','now') AS INTEGER)"""

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

    `2026-11-11T17:04:36-03:00` is one such stamp. `SKILL_LOG_NOW`, when
    set, is the stamp: the test-only clock injection (SPEC §9) is consulted
    first and returned as written, so a case can pin the time without
    touching the store or sleeping.
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
    """The writer's local wall clock, read without touching the store.

    A `--dry-run` preview must write nothing, so the clock is read
    through an in-memory database: the clock lives in the SQLite
    library, not in the file.
    """
    var db = Database(":memory:")
    return local_timestamp(db)


def hostname_unavailable() -> Error:
    """The failure for a machine whose hostname cannot be read."""
    return Error("cannot read this machine's hostname; name it with --machine")


def hostname() raises -> String:
    """This machine's hostname.

    A hostname that cannot be read is an error, not an empty string: the
    machine namespaces the store's markers (`machine#id`), so a row
    without one is a row nothing can resolve. `--machine` is the way out,
    and the failure says so.
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
