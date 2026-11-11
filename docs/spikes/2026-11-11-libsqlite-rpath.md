# Spike: bundled `libsqlite3.so.0` resolves through the binary's `$ORIGIN` rpath

**Ticket:** [#4](https://github.com/Dahep/skill-log/issues/4)
**Feeds:** [#3](https://github.com/Dahep/skill-log/issues/3)
**Date:** 2026-11-11
**Host:** omarchy (desktop), x86_64, glibc
**Toolchain:** Mojo 1.2.0 (2016d0cd) via mise, unmodified
**Binding:** `ehsanmok/sqlite` v0.2.2, commit `c5939d362e40cd473fab08cb92e0ab4de0060f25`,
`sqlite/ffi.mojo` + `sqlite/db.mojo` only (no `orm.mojo`, no `morph`)

## Verdict

**rpath works.**

A Mojo binary built against the vendored binding, packaged with
`patchelf --set-rpath '$ORIGIN/lib'`, resolves the binding's bare-soname
`dlopen("libsqlite3.so.0")` to the `lib/libsqlite3.so.0` shipped beside the
executable — with no conda prefix, no Mojo toolchain, no `LD_LIBRARY_PATH`,
and, in the sandbox, no system SQLite at all. Issue #3's release layout
stands as written.

The negative test also lands where the contract wants it: **one** named
stderr line and **exit 1**, no segfault and no Mojo traceback — but only
because the program catches the binding's error. The one caveat is recorded
under [Caveat](#caveat-the-unhandled-exception-is-a-mojo-diagnostic-not-our-line).

## What was built

A minimal program in `docs/spikes/rpath/`:

- `main.mojo` — `Database(":memory:")`, `CREATE TABLE`, one `INSERT`, a
  prepared `SELECT`, prints the row.
- `sqlite/ffi.mojo`, `sqlite/db.mojo` — the vendored binding, byte for byte.
  `sqlite/__init__.mojo` is trimmed by `package.sh` to drop the upstream
  `from .orm import ...`, because `orm.mojo` is not taken.

The scripts in `docs/spikes/rpath/` reproduce everything below:

```sh
cd docs/spikes/rpath
./package.sh          # build + package into /tmp/opencode/rpath-spike/pkg
./sandbox.sh          # sqlite-free root, positive and negative runs
```

## Commands

```sh
# build
mise x -- mojo build -I /tmp/opencode/rpath-spike/build \
  -o /tmp/opencode/rpath-spike/build/skill-log-spike \
  /tmp/opencode/rpath-spike/build/main.mojo

# package, exactly the release layout of issue #3
cp <build>/skill-log-spike              /tmp/opencode/rpath-spike/pkg/
cp <mojo>/lib/libKGENCompilerRTShared.so   pkg/lib/
cp <mojo>/lib/libMSupportGlobals.so        pkg/lib/
cp <mojo>/lib/libAsyncRTRuntimeGlobals.so  pkg/lib/
cp "$(readlink -f /usr/lib/libsqlite3.so.0)" pkg/lib/libsqlite3.so.0
patchelf --set-rpath '$ORIGIN/lib' pkg/skill-log-spike
```

Note on the SQLite file: this box has `/usr/lib/libsqlite3.so.0` as a
symlink to `libsqlite3.so.3.54.1` (the `libsqlite3.so.0.8.6` named in the
ticket brief does not exist here). The dereferenced file is copied and named
with the **soname** the loader asks for, `libsqlite3.so.0`; the file's own
`DT_SONAME` is `libsqlite3.so.0`, so the name matches.

## Evidence

### 1. `readelf -d` — DT_NEEDED and RUNPATH

```
$ readelf -d pkg/skill-log-spike | grep -iE 'NEEDED|RUNPATH|RPATH'
 0x0000000000000001 (NEEDED)             Shared library: [libKGENCompilerRTShared.so]
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/lib]
```

Only `libKGENCompilerRTShared.so` is a direct `DT_NEEDED`. The other two Mojo
runtime libraries are transitive: `libKGENCompilerRTShared.so` records them as
its own `DT_NEEDED` and carries an `RPATH` of `$ORIGIN:...`, so copying all
three into `lib/` and putting them side by side resolves them together.

### 2. `ldd`

```
$ ldd pkg/skill-log-spike
	linux-vdso.so.1 (0x00007efc81d25000)
	libKGENCompilerRTShared.so => /tmp/opencode/rpath-spike/pkg/lib/libKGENCompilerRTShared.so (0x00007efc81b90000)
	libm.so.6 => /usr/lib/libm.so.6 (0x00007efc81a59000)
	libc.so.6 => /usr/lib/libc.so.6 (0x00007efc81800000)
	libstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x00007efc81400000)
	libMSupportGlobals.so => /tmp/opencode/rpath-spike/pkg/lib/libMSupportGlobals.so (0x00007efc81a47000)
	libAsyncRTRuntimeGlobals.so => /tmp/opencode/rpath-spike/pkg/lib/libAsyncRTRuntimeGlobals.so (0x00007efc80800000)
	libgcc_s.so.1 => /usr/lib/libgcc_s.so.1 (0x00007efc817d30000)
	/lib64/ld-linux-x86-64.so.2 => /usr/lib64/ld-linux-x86-64.so.2 (0x00007efc81d27000)
```

### 3. `LD_DEBUG=libs` — the resolved path

```
$ LD_DEBUG=libs ./skill-log-spike 2>&1 | grep -i sqlite
     28936:	find library=libsqlite3.so.0 [0]; searching
     28936:	  trying file=/tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
     28936:	calling init: /tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
id: 1 | message: Hello, SQLite!
     28936:	calling fini: /tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0 [0]
```

The resolved path is the packaged `lib/` copy.

The untruncated search trace shows *why* — the loader took the caller's
`DT_RUNPATH` and succeeded on the first try, never reaching the ldconfig
cache:

```
     28944:	find library=libsqlite3.so.0 [0]; searching
     28944:	 search path=/tmp/opencode/rpath-spike/pkg/lib		(RUNPATH from file ./skill-log-spike)
     28944:	  trying file=/tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
     28944:	
     28944:	
     28944:	calling init: /tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
```

### 4. Clean environment (`env -i`)

```
$ env -i HOME=/tmp/opencode/rpath-spike/home PATH=/usr/bin:/bin ./skill-log-spike
id: 1 | message: Hello, SQLite!
Done.
exit=0
```

```
$ env -i HOME=/tmp/opencode/rpath-spike/home PATH=/usr/bin:/bin LD_DEBUG=libs ./skill-log-spike 2>&1 | grep -i sqlite
     28967:	find library=libsqlite3.so.0 [0]; searching
     28967:	  trying file=/tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
     28967:	calling init: /tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
id: 1 | message: Hello, SQLite!
     28967:	calling fini: /tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0 [0]
```

Under that environment `mojo` is not on `PATH` and `$HOME` is a scratch
directory with no `.local`:

```
$ env -i HOME=/tmp/opencode/rpath-spike/home PATH=/usr/bin:/bin sh -c 'command -v mojo || echo "mojo: not found"; ls $HOME/.local 2>&1 | head -2'
mojo: not found
ls: cannot access '/tmp/opencode/rpath-spike/home/.local': No such file or directory
```

So neither the toolchain nor a conda prefix can be supplying the library.

### 5. Sandbox: no system SQLite anywhere

`bwrap` (bubblewrap) is used rather than a container — no daemon, no cgroup
namespace, no privileges, and the desktop's live session cgroups are never
touched. The sandbox root holds a copy of `/usr/lib` and `/usr/lib32` with
every `libsqlite3*` removed and no `ld.so.cache`, so the package's
`$ORIGIN/lib` RUNPATH is the only possible source of SQLite.

```
$ ./sandbox.sh
== POSITIVE: bundled libsqlite3.so.0 present, no system SQLite ==
id: 1 | message: Hello, SQLite!
Done.
exit=0

== NEGATIVE: bundled libsqlite3.so.0 removed, no system SQLite ==
exit=1
--- stdout ---
--- stderr ---
skill-log: sqlite unavailable: dlopen failed: libsqlite3.so.0: cannot open shared object file: No such file or directory
--- stderr lines: 1 ---
```

This is the decisive pair: with **no system SQLite on the box at all**, the
bundled copy is found and the program works; with the bundled copy removed,
the program fails with one named stderr line and exit 1.

## Negative test

**exit code: 1. stderr lines: 1.**

```
skill-log: sqlite unavailable: dlopen failed: libsqlite3.so.0: cannot open shared object file: No such file or directory
```

No segfault, no Mojo traceback, nothing on stdout.

### Why the sandbox is required for this test

Removing `lib/libsqlite3.so.0` on the dev box is *not* enough — the loader
falls through to the ldconfig cache and finds the distro copy:

```
     29129:	find library=libsqlite3.so.0 [0]; searching
     29129:	 search path=/tmp/opencode/rpath-spike/pkg/lib		(RUNPATH from file ./skill-log-spike)
     29129:	  trying file=/tmp/opencode/rpath-spike/pkg/lib/libsqlite3.so.0
     29129:	    (no such file)
     29129:	 search cache=/etc/ld.so.cache
     29129:	  trying file=/usr/lib/libsqlite3.so.0
     29129:	calling init: /usr/lib/libsqlite3.so.0
```

The RUNPATH is searched first, so the bundled copy always wins over a system
copy; but a system copy backstops it when the bundled one is missing. Only a
root without SQLite exercises the failure path.

## Caveat: the unhandled exception is a Mojo diagnostic, not our line

The one stderr line above is produced by the spike's own `try`/`except`. The
vendored binding raises the `dlopen` failure out of `Database.__init__`, so a
program that does **not** catch it gets Mojo's runtime diagnostic instead —
two lines, and neither is a named error of ours:

```
$ (uncaught variant, bundled copy removed, no system SQLite)
exit=1
--- stderr ---
stack trace was not collected. Enable stack trace collection with environment variable `MODULAR_DEBUG=stack-trace-on-error`
Unhandled exception caught during execution: dlopen failed: libsqlite3.so.0: cannot open shared object file: No such file or directory
--- stderr lines: 2 ---
```

With `MODULAR_DEBUG=stack-trace-on-error` the first line is replaced by a
Mojo stack dump (nine frames), so the failure is noisier still.

**This is a CLI obligation, not a blocker for the rpath.** Issue #3's
contract already says one stderr line per failure and no tracebacks; that
means the CLI must construct the `Database` inside a `try` and map the error
to its own named line, exactly as the spike does. The binding's behaviour
gives the CLI the message it needs (`dlopen failed: libsqlite3.so.0: cannot
open shared object file: No such file or directory`) — it just must not be
allowed to escape.

## Consequences

- **#3's release layout stands as written.** `lib/` holds the three Mojo
  runtime `.so` files plus `libsqlite3.so.0`, and
  `patchelf --set-rpath '$ORIGIN/lib'` is enough to make the vendored
  binding find the bundled SQLite.
- **No patch to the vendored `ffi.mojo` is needed.** The
  `$ORIGIN`-relative probe and the `SKILL_LOG_SQLITE` override that the
  ticket sketched as fallback are not required for this question.
- **One packaging detail is now known:** `libMSupportGlobals.so` and
  `libAsyncRTRuntimeGlobals.so` are not direct `DT_NEEDED` of the binary;
  they come in through `libKGENCompilerRTShared.so`, whose own `RPATH`
  contains `$ORIGIN`. They must sit in the same `lib/` directory as
  `libKGENCompilerRTShared.so`, which the layout already does.
- **The CLI must catch the binding's error** and print one named stderr
  line. That is a change to *our* code, not to the vendored binding.

## Notes on method

- The ticket's "rename the whole Mojo toolchain out of the way" step was
  deliberately **not** performed. The `env -i` run with a scratch `$HOME`
  and a `PATH` of `/usr/bin:/bin` proves the toolchain plays no part (the
  toolchain lives under `$HOME/.local/share/mise`, and `$HOME` there is
  empty), and the sandbox removes the system library as well. The installed
  toolchain was left exactly as found: `pypi-mojo/1.2.0` is in place and
  `latest -> ./1.2.0` is unchanged.
- Nothing outside the repository checkout and `/tmp/opencode` was modified.
