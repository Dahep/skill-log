"""The SQLite preflight: is the library there at all?"""

from sqlite.db import Database
from skill_log.errors import Failure, operational_failure


def preflight() raises -> Optional[Failure]:
    """Load the vendored SQLite binding once."""
    try:
        var db = Database(":memory:")
        _ = db
    except e:
        return operational_failure("sqlite unavailable: " + String(e))
    return None
