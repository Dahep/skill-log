# ADR-0001: a Mojo binary with a vendored SQLite binding

**Status:** accepted, 2026-11-11.
**Amends:** the implementation clauses of [issue #1](../../../issues/1) (language,
distribution, test suite). The behavior contract there is unchanged.
**Spec:** [issue #3](../../../issues/3).

## Context

The tool currently lives in the dotfiles repo: a Python script installed by
stow, a `post-merge` hook wired by a dotfiles setup step, and a dotfiles skill
teaching it. Issue #1 moved the product contract into this project, but the
implementation still has no independent lifecycle: versioning is "whatever the
checkout is today", installing means cloning and stowing dotfiles, and a new
machine only gets the log if it gets the whole dotfiles repo first.

The contract itself is settled and tested — per-machine ownership, resolution
by the commit that carries the report, owner-wins sync, hidden-marker
reporting. What is missing is a distributable artifact and a version.

We want a **single binary**, implemented in Mojo, installable with one mise
command.

## Decision

1. **Language: Mojo 1.2**, toolchain pinned as a mise tool (`pypi:mojo@1.2.0`).
   `mojo build` produces the executable.
2. **Storage: SQLite, unchanged**, reached through `ehsanmok/sqlite` v0.2.2
   (MIT), vendored as `vendor/sqlite/{ffi,db}.mojo`, with the ORM layer and its
   `morph` dependency left out. The store schema, migrations and SQL are the
   ones #1 defines.
3. **Artifact:** a release tarball containing the executable plus `lib/` — the
   three Mojo runtime `.so` files and `libsqlite3.so.0` — with
   `patchelf --set-rpath '$ORIGIN/lib'`.
4. **Distribution:** GitHub releases, installed with mise's
   `github:Dahep/skill-log` backend.
5. **Platform:** `x86_64-unknown-linux-gnu` only for 1.0.
6. **Skills:** two bundled skills, each rendered from a user-owned template
   under XDG config (`skill-log` is copied; `skill-friction-review` is
   rendered), with a fenced usage-log block adopted into every skill in a repo.

## Why these

- **`mojo build` cannot link a C library.** It rejects `-l`, `-L`, `--link-arg`
  and `-Wl,...`, and `--emit object` is experimental. Everything is reached
  through `std.ffi.OwnedDLHandle` (`dlopen` + `dlsym`), which is also how
  `ehsanmok/sqlite` loads SQLite. Verified on this machine: a Mojo binary
  called `sqlite3_libversion_number` through `dlopen`.
- **A Mojo binary is not self-contained by default.** `mojo build` records
  absolute paths to three runtime libraries inside the toolchain installation.
  Copying them into `lib/` and repointing the rpath was verified by renaming
  the entire toolchain away and running the binary successfully.
- **`ubi:` is deprecated** (mise 2026.4, removed 2027.1). The `github:` backend
  replaces it and verifies release digests, which is a better guarantee than
  the local checksum ubi recorded.
- **Keeping SQLite keeps the tested contract.** The schema, the origin-id
  merge rule, transactions and the WAL/busy behaviour are already implemented
  and covered; a custom store would have re-derived all of it.

## Consequences

**Positive**

- One artifact, one version, one install command; a new machine does not need
  dotfiles to get the log.
- No store migration: the existing database file is the same schema.
- `add` stays transactional; the vendored binding gives prepared statements
  and automatic rollback.
- Release archives are attestation-verifiable by mise.

**Negative**

- The artifact carries ~3.4 MB of bundled shared libraries.
- No cross-compilation: each platform is built on its own runner, so a second
  platform is a new CI matrix entry, not a flag.
- glibc floor: the binary runs where the runner's glibc runs.
- Mojo 1.2 has no calendar/timezone, no regex, no argument parser and no JSON
  parser, so local dates need libc `localtime_r`/`strftime`, and git calls need
  `fork`/`exec`/`wait` because `std.subprocess.run` is `popen` without an exit
  status.
- A vendored third-party package (one maintainer, 0.2.x) has to be
  copy-forwarded deliberately.
- The binary's runtime is tied to the compiler release; a Mojo upgrade is a
  rebuild.

## Enforced by

- Packaging spike ([#4](../../../issues/4)): a bundled `libsqlite3.so.0` must
  resolve through the rpath with no toolchain, no conda prefix and no system
  SQLite present.
- Packaging test in CI: install the release archive into a clean container and
  run `--version` and `setup --dry-run`.

## Alternatives rejected

- **Python + pipx / PyPI.** Still needs a Python 3.12 interpreter per machine,
  and produces a console script rather than an artifact. The contract is
  language-agnostic, so this remains the fallback if the Mojo work stalls.
- **A hand-rolled JSONL store.** Drafted in the first revision of #3 and
  dropped: it re-implements id allocation, locking, atomic multi-row writes,
  corruption handling and compaction, and would have needed a JSON parser. The
  ecosystem binding removes all of that.
- **`ubi:` backend.** Deprecated; see above.
- **Static or musl-linked binary.** Not possible with `mojo build` today.
- **DuckDB (`sbrunk/duckdb.mojo`).** A real binding, but an analytical engine
  is the wrong shape for a per-invocation row log.
