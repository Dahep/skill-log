# ADR-0004: a Go binary with a pure-Go SQLite driver

**Status:** accepted, 2026-11-12.
**Supersedes:** the implementation clauses of
[ADR-0001](0001-mojo-binary-and-sqlite.md) — language, storage binding,
artifact layout, and the packaging consequences that follow from them. The
behavior contract ADR-0001 amended is unchanged.
**Current rules:** [SPEC.md](../../SPEC.md) §8.

## Context

ADR-0001 chose a Mojo binary with a vendored `ehsanmok/sqlite` binding and a
release archive that shipped the executable beside `lib/` — three Mojo runtime
shared objects and a pinned jammy `libsqlite3.so.0` — with
`patchelf --set-rpath '$ORIGIN/lib'` pointing at them. Every one of those
choices was forced by the toolchain rather than chosen: `mojo build` cannot
link a C library, cannot produce a static binary, and records absolute paths
into its own installation. The rpath spike
([#4](https://github.com/Dahep/skill-log/issues/4),
[docs/spikes/2026-11-11-libsqlite-rpath.md](../spikes/2026-11-11-libsqlite-rpath.md))
proved the layout works, and it also priced it: a `patchelf` step in every
build, a pinned Ubuntu package fetched and hash-verified on the release
runner, a glibc floor, and four shared objects in the archive.

The port is now written in Go. The behaviour contract is unchanged — the same
CLI, the same store schema, the same markers, the same reports — and the
suites are the same black-box suites. What changed is the implementation
substrate, and with it the shape of the release artifact.

Go removes the whole constraint set at once. `CGO_ENABLED=0` produces a
statically linked executable; the standard library ships
`database/sql`, `os/exec`, `time`, `os.Hostname` and a JSON encoder; and the
SQLite problem has a pure-Go answer: `modernc.org/sqlite`, a transpilation of
the SQLite C amalgamation to Go, with no cgo and no C toolchain.

## Decision

1. **Language: Go**, module `github.com/Dahep/skill-log`, the toolchain
   pinned as a mise tool and locked in `mise.toml`. The module targets the Go
   version named in `go.mod`; the build is `CGO_ENABLED=0 go build`.

2. **Storage: SQLite through `modernc.org/sqlite`**, a pure-Go driver. It is
   pinned by `go.mod` and `go.sum`, so the exact version — and every
   transitive module's exact version — is recorded and verifiable. There is no
   vendored copy, no copy-forward, and no separate licence to track: the
   module cache carries each dependency's licence, and `THIRD_PARTY_NOTICES.md`
   names them.

3. **Artifact: one statically linked executable.** The release archive is
   `skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz` and holds the `skill-log`
   binary plus the licence and notice files. There is no `lib/` directory: the
   SQLite implementation is inside the executable.

4. **Versioning**: semantic versioning, release tag `vX.Y.Z`, baked into the
   binary at build time with `-ldflags -X` against
   `internal/cli.version`.

5. **Platform**: `x86_64-unknown-linux-gnu` for 1.0. The artifact is static,
   so it carries no glibc floor from a bundled library; the Go runtime's own
   requirements are the only floor.

6. **Behaviour is unchanged.** The store schema, the marker grammar, the
   report contract, the CLI surface and the exit codes are the ones ADR-0001
   and ADR-0002 defined. This record changes how the artifact is built and
   shipped, not what the tool does.

## Why these

- **A pure-Go driver removes the C toolchain from the release.** `mattn/go-sqlite3`
  is the obvious alternative and the wrong one here: it is a cgo binding, so
  building it needs a C compiler on every machine that builds the project and
  on the release runner, and the resulting binary carries a C library whose
  glibc floor is the builder's. `modernc.org/sqlite` needs neither — it is
  Go source, it compiles with `CGO_ENABLED=0`, and `go.sum` pins it.

- **One static binary removes the layout problem entirely.** The Mojo
  release needed `lib/` because the runtime's shared objects could not be
  linked in and the SQLite library could not be linked at all. A Go binary
  needs nothing beside it, so the archive is one file plus the licence and
  notice files — and the loader has no way to resolve the wrong SQLite,
  because there is no dynamic lookup to get wrong.

- **The dependency graph is recorded, not copied.** ADR-0001's vendored
  binding was a deliberate copy-forward of a third-party package at version
  0.2.x, with the upstream commit recorded in the tree. `go.mod` and
  `go.sum` record the same thing more precisely, and `go mod verify` checks
  it.

- **The standard library replaces the hand-written pieces the Mojo build
  needed.** ADR-0001's "hand-written infrastructure" list was long partly
  because Mojo 1.2 had no calendar, no regex, no argument parser and no JSON
  parser: the writer's clock, the hostname, process execution and the JSON
  writer were all obligations. In Go the clock (`time`), the hostname
  (`os.Hostname`) and the process runner (`os/exec`) are standard-library
  calls, and the JSON writer stays hand-written for the reason it always was:
  `encoding/json` would HTML-escape characters the tool's own output is
  allowed to carry. The port reads exactly one JSON value — opencode's stored
  model — through a targeted scanner that keeps the reference's documented
  fallback, passing an unparseable value through raw rather than mangling it.

- **The store contract does not move.** ADR-0002's refusal taxonomy is a
  value carried by the store layer, not a word re-derived from an error
  message. A different driver does not change that, and the suites are the
  same black-box suites: they assert on the CLI, so a change of driver is
  invisible to them unless it changes behaviour.

## Consequences

**Positive**

- The release build is one command with no native dependencies:
  `CGO_ENABLED=0 go build`. No `patchelf`, no C compiler, no pinned SQLite
  package to fetch and hash-verify on the runner.
- The artifact is self-contained: it runs on a machine with no Go toolchain,
  no system SQLite and no loader search path.
- The spike's question — "does a bundled `libsqlite3.so.0` resolve through
  the rpath?" — is gone rather than answered. There is no bundled library, so
  there is no rpath, no `$ORIGIN`, no `lib/` directory and no "the bundled
  copy is the one that loaded" assertion to make.

**Negative**

- The build now depends on a Go toolchain. The pin lives in `mise.toml` and
  `mise.lock`, and the module targets the Go version named in `go.mod`; a
  machine that builds the project needs that toolchain installed.
- The binary is larger than a Mojo build would have been, because the SQLite
  implementation is compiled into it. It is one file, not one file plus four
  shared objects.
- A pure-Go SQLite is not the same SQLite as the C library. It is a
  transpilation, so behaviour differs at the margins — in the SQL features
  it implements, in performance, and in edge cases around locking and
  corruption. The tool's SQL stays inside the ordinary subset, but a
  divergence is now possible where a C-linked build would have matched the
  system library exactly.
- The dependency set is now ten modules rather than one vendored binding.
  That is more to audit, and it is only tractable because `go.sum` pins
  every version and `THIRD_PARTY_NOTICES.md` records every licence.
- A Go upgrade is a rebuild, and a `modernc.org/sqlite` upgrade is a
  deliberate `go get` — the same copy-forward discipline ADR-0001 had, with
  the version recorded rather than the source.

## Alternatives rejected

- **Mojo with a vendored binding, as ADR-0001 chose.** It worked, and the
  spike proved it. It also required a `patchelf` step, a pinned jammy SQLite
  package, a glibc floor, four shared objects in the archive, and a
  hand-written clock, hostname reader, process runner and JSON writer. The
  Go port delivers the same behaviour with none of that.
- **cgo with `mattn/go-sqlite3`.** A C toolchain on every build machine and
  a glibc floor on the artifact, for a driver whose pure-Go counterpart
  exists and is pinned the same way.
- **A different embedded database** (bbolt, etc.). The store contract is
  SQLite: the schema is stamped with `PRAGMA user_version`, the refusal
  taxonomy distinguishes a foreign SQLite file from a skill-log store, and
  the suites assert on SQLite files on disk. Changing the store engine is a
  schema change, not a packaging change.
- **A pure-Go SQLite with a different module** (`zombiezen.com/go/sqlite`,
  `crawshaw.io/sqlite`). `modernc.org/sqlite` is the maintained one, it is
  the direct dependency the graph is pinned around, and its own
  `LICENSE-3RD-PARTY.md` accounts for everything it links in — which is what
  makes this record's notices list verifiable.
- **A pure-Go SQLite without the C amalgamation's licence.** SQLite itself is
  public domain, but the transpiled code and the surrounding module carry
  their own licences; `THIRD_PARTY_NOTICES.md` records them rather than
  assuming the public-domain status covers the whole tree.

## Enforced by

- The build is `CGO_ENABLED=0 go build`, and the packaging test — once it is
  ported to the static layout — proves the artifact is statically linked and
  runs in a container with no system SQLite.
- `go.mod` and `go.sum` pin every module version; `go mod verify` checks the
  module cache against them.
- `THIRD_PARTY_NOTICES.md` names every module the build includes and the
  licence read from that module's own tree.
