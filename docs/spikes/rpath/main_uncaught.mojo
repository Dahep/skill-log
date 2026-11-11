"""Variant of the spike program whose failure path is NOT caught.

The vendored binding raises the dlopen error out of ``Database.__init__``,
so an uncaught variant shows what a Mojo program prints when it does not
catch: Mojo's runtime prints its own two-line diagnostic instead of the
one named line the CLI contract requires.  The caught variant lives in
``main.mojo`` and is the one the spike verdict rests on.
"""

from sqlite.db import Database


def main() raises:
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
