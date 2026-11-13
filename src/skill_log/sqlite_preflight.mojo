"""The SQLite preflight: is the library there at all?"""

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
