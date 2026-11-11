# Vendored code

`ffi.mojo` and `db.mojo` are copied **byte for byte** from
[`ehsanmok/sqlite`](https://github.com/ehsanmok/sqlite):

| | |
|---|---|
| URL | `https://github.com/ehsanmok/sqlite.git` |
| tag | `v0.2.2` |
| commit | `c5939d362e40cd473fab08cb92e0ab4de0060f25` |
| commit date | 2026-10-22 |
| license | MIT — the upstream text is in `LICENSE` next to this file |

## What is *not* vendored

- `orm.mojo` — the ORM layer. Issue #3 excludes it: the tool writes and reads
  the store through prepared statements, and the ORM adds a dependency
  (`morph`) for no gain.
- `morph` — the ORM's dependency, for the same reason.

`__init__.mojo` is **not** copied from upstream: the upstream file imports
`sqlite.orm`, which is not vendored. The file here is a local trim that
exposes only `sqlite.db`.

## Upgrades

Copy-forward, deliberately, never a live dependency: the tool's only durable
store must not break because a small package renamed a method. An upgrade is
a new tag, a new commit hash, and a new copy of these files — with the
packaging spike (#4) re-run to confirm the rpath still resolves.

The packaging spike
([#4](../../../docs/spikes/2026-11-11-libsqlite-rpath.md)) proved that the
upstream files need no local patch: the bare-soname `dlopen` of
`libsqlite3.so.0` resolves through the executable's `$ORIGIN/lib` runpath.
