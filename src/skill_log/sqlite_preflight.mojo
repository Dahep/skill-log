"""The SQLite preflight.

The vendored binding reaches SQLite through `dlopen("libsqlite3.so.0")`.
The release ships that library in `lib/` beside the executable and resolves
it through the binary's `$ORIGIN/lib` runpath, so the artifact runs on a
machine with no system SQLite.

The preflight loads the binding once at startup, before dispatch, for every
invocation — `--version` and `--help` included. That has two purposes:

1. A missing or unloadable `libsqlite3.so.0` becomes one named stderr line
   and exit 1, instead of a Mojo traceback or a segfault.
2. Every later verb inherits the same failure path for free, because the
   store it will open is the same library.

The probe opens an in-memory database, so nothing is created on disk.
"""

from sqlite.db import Database
from skill_log.errors import Failure, operational_failure


def preflight() raises -> Optional[Failure]:
    """Load the vendored SQLite binding once.

    Returns `None` when the binding is loadable, and the failure to report
    otherwise. The failure is already named `sqlite unavailable: ...` and
    carries the operational exit code.
    """
    try:
        var db = Database(":memory:")
        _ = db
    except e:
        return operational_failure("sqlite unavailable: " + String(e))
    return None
