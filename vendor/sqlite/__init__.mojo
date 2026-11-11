"""The vendored SQLite binding: FFI plus the safe API, and nothing else.

Upstream ``ehsanmok/sqlite`` also ships an ORM layer (``sqlite.orm``) built
on ``morph``.  Issue #3 excludes both: the ORM's dependency is not vendored,
and the tool talks to SQLite through prepared statements directly.  This
``__init__.mojo`` therefore exposes only what ``sqlite.db`` provides, which
is the same trim the packaging spike (#4) proved out.
"""

from .db import Database, Statement, Row, Transaction
