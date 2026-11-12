# libsqlite3 `$ORIGIN` rpath spike (ticket #4)

> **Historical record.** This directory holds the Mojo-era spike that
> answered the bundled-SQLite question: yes, a packaged `libsqlite3.so.0`
> resolves through an `$ORIGIN` rpath. The project moved to a Go binary with
> a pure-Go SQLite driver
> ([ADR-0004](../../adr/0004-go-binary-and-pure-go-sqlite.md)), so the
> question no longer arises: the artifact is statically linked, there is no
> bundled library and no rpath. The files are kept as the record of what was
> tried and why — they are not part of any current build.

Does a Mojo binary built against the vendored `ehsanmok/sqlite` binding find
the `libsqlite3.so.0` we ship in `lib/` beside the executable, once
`patchelf --set-rpath '$ORIGIN/lib'` is applied?

**Verdict: rpath works.** See `../2026-11-11-libsqlite-rpath.md` for the full
evidence.

## What is here

| Path | What it is |
| --- | --- |
| `main.mojo` | the spike program: open `:memory:`, create a table, insert a row, select it, print it. The failure path is caught so the program prints one named stderr line and exits 1, which is what the CLI contract requires. |
| `main_uncaught.mojo` | the same program without the `try`/`except`, kept so the difference the CLI is obliged to make stays visible and reproducible. |
| `sqlite/ffi.mojo` | the vendored binding's FFI layer, byte for byte from `ehsanmok/sqlite` v0.2.2. |
| `sqlite/db.mojo` | the vendored binding's safe API, byte for byte from `ehsanmok/sqlite` v0.2.2. |
| `package.sh` | builds the spike and packages it exactly like the release layout of issue #3, then prints `readelf -d` and `ldd`. |
| `sandbox.sh` | builds a root filesystem with no `libsqlite3` at all and runs the package inside it (bubblewrap), positive and negative. |

`orm.mojo` is deliberately absent: issue #3 excludes the ORM layer and its
`morph` dependency.

## Reproducing

Both scripts take an optional scratch directory and default to
`/tmp/opencode/rpath-spike`.

```sh
cd docs/spikes/rpath
./package.sh          # build + package into $SCRATCH/pkg
./sandbox.sh          # sqlite-free root, positive and negative runs
```

Requirements: `mojo` 1.2.0 through mise (`mise x -- mojo ...`), `patchelf`,
`bwrap`, and `readelf`/`ldd` from binutils. Nothing outside the scratch
directory and the repository is touched.

## What `package.sh` does

1. Copies `sqlite/ffi.mojo` and `sqlite/db.mojo` into a build directory and
   writes a trimmed `sqlite/__init__.mojo` (the upstream one imports
   `sqlite.orm`).
2. `mise x -- mojo build -I <build> -o <build>/skill-log-spike main.mojo`.
3. Copies the binary to the package root and the three Mojo runtime
   libraries plus `libsqlite3.so.0` into `lib/`. The SQLite file is the
   dereferenced target of the distribution's soname symlink, renamed to the
   soname the loader asks for (`libsqlite3.so.0`).
4. `patchelf --set-rpath '$ORIGIN/lib'`.

## What `sandbox.sh` does

`bwrap` is used rather than a container: no daemon, no cgroup namespace, no
privileges, and the desktop's live session cgroups are never touched. The
sandbox root contains a copy of `/usr/lib` and `/usr/lib32` with every
`libsqlite3*` removed and no `ld.so.cache`, so the packaged binary's
`$ORIGIN/lib` RUNPATH is the only possible source of SQLite.

## The one caveat this spike surfaces

`libsqlite3` is found through the RUNPATH, but only because the *caller* of
`dlopen` is the executable itself. The loader's search order for a
slash-less name is: the caller's `DT_RUNPATH`, then `LD_LIBRARY_PATH`, then
the `ld.so.cache`, then the default paths. The RUNPATH is consulted first, so
the bundled copy wins over any system copy — but a system copy still
backstops it when the bundled one is missing. That is what makes the negative
test need a sandbox rather than a plain `mv`.
