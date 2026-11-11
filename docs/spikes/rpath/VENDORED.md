# Vendored code in this spike

`sqlite/ffi.mojo` and `sqlite/db.mojo` are copied **byte for byte** from
[`ehsanmok/sqlite`](https://github.com/ehsanmok/sqlite):

- version: `v0.2.2`
- commit: `c5939d362e40cd473fab08cb92e0ab4de0060f25`
- license: MIT — see <https://github.com/ehsanmok/sqlite/blob/v0.2.2/LICENSE>

`sqlite/__init__.mojo` is **not** copied: the upstream file imports
`sqlite.orm`, and issue #3 excludes the ORM layer and its `morph`
dependency. `package.sh` writes a trimmed replacement at build time that
exposes only `sqlite.db`.

This spike copies the two files only to have a buildable subject for the
rpath question. Ticket #7 owns the real vendoring into `vendor/sqlite/`.
