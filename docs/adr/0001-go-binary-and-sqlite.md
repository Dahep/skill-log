# ADR-0001: a Go binary with pure-Go SQLite

**Status:** accepted, 2026-11-12.
**Current rules:** [SPEC.md](../../SPEC.md) §8.

## Context

skill-log must ship as one distributable executable. The release should be
installable without a Go toolchain or a system SQLite library, and the local
store should remain a SQLite file under the user's XDG state directory. The
tool has no daemon and no network: each machine owns one store, and the CLI is
the only public surface.

That shape calls for a self-contained binary. SQLite is the right store because
its file format, schema version pragma and transaction semantics support the
tool's refusal taxonomy and atomic writes. A cgo SQLite driver would make the
release depend on a C toolchain and carry the builder's dynamic-library
floor. A server or daemon would add a lifecycle, transport and compatibility
surface to a tool whose data is local and whose CLI is already the contract.

## Decision

1. **Language: Go**, module `github.com/Dahep/skill-log`. The toolchain is
   pinned as a mise tool and locked in `mise.toml`. The module targets the Go
   version named in `go.mod`; the build is `CGO_ENABLED=0 go build`.

2. **Storage: SQLite through `modernc.org/sqlite`**, a pure-Go driver. The
   driver and every transitive module are pinned by `go.mod` and `go.sum`, so
   the exact dependency versions are recorded and verifiable. There is no
   vendored copy and no separate licence to track beyond
   `THIRD_PARTY_NOTICES.md`.

3. **Artifact: one statically linked executable.** The release archive is
   `skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz` and holds the `skill-log`
   binary plus the licence and notice files. The SQLite implementation is
   compiled into the executable; there is no `lib/` directory.

4. **Versioning:** semantic versioning, release tag `vX.Y.Z`, baked into the
   binary at build time with `-ldflags -X` against `internal/cli.version`.

5. **Distribution:** GitHub releases installed through mise's
   `github:Dahep/skill-log` backend, which verifies the release digest. The
   release archive contains only the executable and licence files.

6. **Platform:** `x86_64-unknown-linux-gnu` for 1.0. The artifact is static,
   so the Go runtime's requirements are the only platform floor.

## Why these

- **A pure-Go driver removes the C toolchain from the release.**
  `mattn/go-sqlite3` is a cgo binding: building it needs a C compiler on every
  build machine and release runner, and the resulting binary carries a C
  library whose glibc floor is the builder's. `modernc.org/sqlite` is Go
  source, compiles with `CGO_ENABLED=0`, and is pinned by `go.sum`.

- **One static binary keeps distribution simple.** The archive has no runtime
  libraries beside the executable, so it has no loader path to resolve and no
  bundled library that could load instead of the expected one.

- **The dependency graph is recorded, not copied.** `go.mod` and `go.sum`
  record exact versions, and `go mod verify` checks the module cache against
  them. `THIRD_PARTY_NOTICES.md` records the licences of the modules linked
  into the binary.

- **The build is reproducible from recorded inputs.** The Go version, module
  versions, linker flags and archive contents are fixed in the repository and
  release workflow.

- **The store contract stays independent of the driver.** The tool asserts on
  the CLI, the store schema and the SQLite file on disk; the driver's
  implementation differences do not become a second contract.

## Consequences

- The build depends on the pinned Go toolchain. A machine that builds the
  project needs that toolchain installed; a machine that installs the release
  does not.
- The executable is larger because the SQLite implementation is compiled into
  it, but it is one self-contained file.
- A pure-Go SQLite is a transpilation of SQLite rather than the C library.
  Behaviour can differ at the margins in SQL features, performance, locking
  and corruption edge cases. The tool's SQL stays inside the ordinary subset,
  but a divergence from a C-linked build is possible.
- The dependency set contains several modules rather than one embedded
  binding. `go.sum` pins every version, and `THIRD_PARTY_NOTICES.md` records
  every licence.
- Go and driver upgrades are deliberate dependency changes, with versions
  recorded in `go.mod` and `go.sum`.
- Version 1.0 supports one target platform. Supporting another platform adds a
  build and release target.

## Alternatives rejected

- **cgo SQLite.** `mattn/go-sqlite3` would require a C compiler on every build
  machine and give the artifact the builder's dynamic-library floor, while a
  pure-Go counterpart provides the same store contract.
- **A server or daemon.** A local CLI needs no transport, lifecycle or
  compatibility protocol. A daemon would add those obligations without adding
  a capability required by [SPEC.md](../../SPEC.md).
- **A different embedded database.** The store contract is SQLite: the schema
  is stamped with `PRAGMA user_version`, the refusal taxonomy distinguishes a
  foreign SQLite file from a skill-log store, and the tests assert on SQLite
  files on disk.
- **A different pure-Go SQLite module.** `modernc.org/sqlite` is maintained and
  its own notices account for the code it links in.
- **A hand-rolled JSONL store.** It would reimplement id allocation,
  locking, atomic multi-row writes, corruption handling and compaction.

## Enforced by

- The build is `CGO_ENABLED=0 go build`, and the packaging test proves the
  artifact is statically linked and runs in a clean container with no system
  SQLite.
- `go.mod` and `go.sum` pin every module version; `go mod verify` checks the
  module cache against them.
- `THIRD_PARTY_NOTICES.md` names every module the build includes and the
  licence read from that module's own tree.
