# Third-party notices

The `skill-log` binary is built from Go and includes the packages listed
below. The SQLite implementation is a pure-Go driver, so there is no C
library, no shared object and no runtime dependency to ship beside the
executable: everything the binary links is listed here.

Each licence below was read from the module's own tree in the Go module cache
(`go mod download` then `go env GOMODCACHE`), not from a secondary index. The
versions are the ones `go.mod` and `go.sum` pin.

## The direct dependency

| Module | Version | Licence | What it is |
|---|---|---|---|
| [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite) | v1.62.0 | BSD-3-Clause | The SQLite driver: the SQLite C amalgamation translated to Go. It is the only direct requirement in `go.mod`, and it is what makes `CGO_ENABLED=0` possible. |

`modernc.org/sqlite` is BSD-3-Clause (its `LICENSE`). It also carries
`LICENSE-3RD-PARTY.md`, which accounts for everything the driver links in —
the transpiled SQLite itself (public domain), `sqlite-vec` (MIT), and the
modules below — with every licence text reproduced in full.

## The transitive dependencies

These are pinned by `go.sum` and required by `modernc.org/sqlite` through
`modernc.org/libc` and `modernc.org/mathutil`.

| Module | Version | Licence | What it is |
|---|---|---|---|
| [`modernc.org/libc`](https://pkg.go.dev/modernc.org/libc) | v1.80.1 | BSD-3-Clause | The libc layer the transpiled SQLite runs on. |
| [`modernc.org/mathutil`](https://pkg.go.dev/modernc.org/mathutil) | v1.7.1 | BSD-3-Clause | The numeric helpers the transpiled libc uses. |
| [`modernc.org/memory`](https://pkg.go.dev/modernc.org/memory) | v1.12.1 | BSD-3-Clause | The allocator the transpiled libc uses. Its tree carries additional licence files (`LICENSE-GO`, `LICENSE-MMAP-GO`, `LICENSE-LOGO`) for the parts it inherited from Go and from the mmap implementation. |
| [`github.com/dustin/go-humanize`](https://pkg.go.dev/github.com/dustin/go-humanize) | v1.1.0 | MIT | Human-readable size and number formatting. |
| [`github.com/google/uuid`](https://pkg.go.dev/github.com/google/uuid) | v1.6.0 | BSD-3-Clause | UUID handling in the transpiled libc. |
| [`github.com/mattn/go-isatty`](https://pkg.go.dev/github.com/mattn/go-isatty) | v0.0.24 | MIT | Terminal detection. |
| [`github.com/ncruces/go-strftime`](https://pkg.go.dev/github.com/ncruces/go-strftime) | v1.1.0 | MIT | `strftime` for the transpiled libc. |
| [`github.com/remyoudompheng/bigfft`](https://pkg.go.dev/github.com/remyoudompheng/bigfft) | v0.0.0-20230129092748-24d4a6f8daec | BSD-3-Clause | Fast Fourier transform, used by the transpiled libc. |
| [`golang.org/x/sys`](https://pkg.go.dev/golang.org/x/sys) | v0.49.0 | BSD-3-Clause | System calls for the platforms the driver supports. |

## The licence texts

The full texts are in the module cache, in each module's own tree:

```sh
go mod download
MC="$(go env GOMODCACHE)"
cat "$MC/modernc.org/sqlite@v1.62.0/LICENSE"
```

`modernc.org/sqlite`'s own `LICENSE-3RD-PARTY.md` reproduces the licence
texts of everything it links in, with the copyright notices merged in place.

## This project

The project itself is [MIT](LICENSE), Copyright (c) 2026 the skill-log
authors.
