"""Spike program for ticket #4: does a bundled libsqlite3.so.0 resolve
through the binary's $ORIGIN rpath?

Opens an in-memory database, creates a table, inserts one row, selects it
and prints it.

The failure path mirrors what the real CLI must do: catch the error and
print ONE named line to stderr, exit 1.
"""

from sqlite.db import Database
from std.sys import stderr, exit


def main():
    try:
        var db = Database(":memory:")
        db.execute("CREATE TABLE greetings (id INTEGER, message TEXT)")
        db.execute("INSERT INTO greetings VALUES (1, 'Hello, SQLite!')")

        var stmt = db.prepare("SELECT id, message FROM greetings")
        while True:
            var maybe_row = stmt.step()
            if not maybe_row:
                break
            ref row = maybe_row.value()
            print("id:", row.int_val(0), "| message:", row.text_val(1))

        print("Done.")
    except e:
        print("skill-log: sqlite unavailable: " + String(e), file=stderr)
        exit(1)
