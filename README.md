# skill-log

A local log of agent-skill invocations: one row per run, plus the problems
that cost it, so friction can be counted, attributed to a skill, and closed by
a specific change.

**Status:** the Go implementation is complete and every suite passes, including
the parity gate. The specification is [SPEC.md](SPEC.md); the decisions behind
it are in [docs/adr/](docs/adr/), and the vocabulary in [CONTEXT.md](CONTEXT.md).
The Python implementation it replaces is archived verbatim in
[`reference/`](reference/README.md): that tree is the parity ground truth for
the port, not the shipped tool.

## What it is

Agent skills end a run by writing one row: when, which skill, harness, session,
parent, model, repo, worktree, project, and machine. Problems ride as separate
rows attached to the invocation, so a clean run still counts as a denominator
and problems-per-invocation stays measurable.

The store is one SQLite file under the XDG state directory. There is no
daemon and no network: one store per machine, and rows carry the machine that
wrote them so the marker grammar and any external consumer keep an origin.

A change closes the rows it fixes by committing a report file (or, in repos
that cannot carry one, a marker trailer) naming `machine#id` markers. A
post-merge hook stamps the resolved rows, so the log records when and where
the friction closed.

A bundled `skill-friction-review` skill reads the log and decides what to fix;
it never marks a row resolved itself. [SPEC.md](SPEC.md) defines that session
and the resolution rules.

## Install

```bash
mise use -g github:Dahep/skill-log@1.0.0
skill-log setup --repo ~/dotfiles --skills-dir ~/dotfiles/.agents/skills
```

`mise use -g github:Dahep/skill-log@<tag>` installs the released archive
through mise's `github:` backend: it downloads the
`skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz` asset of that tag's
release and verifies the digest the release records. The archive holds one
statically linked `skill-log` executable plus the licence and notice files —
no runtime libraries, so the install works on any Linux machine with no Go
toolchain and no system SQLite. Pin a version by
the tag (`@1.0.0`); `@latest` takes the newest release.

`setup` provisions the store, the post-merge hook, the repo report directory,
and both bundled skills. `setup --check` verifies the result without writing.
`setup --dry-run` shows what a real run would change.

## Build and test

```bash
scripts/build.sh    # dist/skill-log: one statically linked executable
scripts/test.sh     # the suites against dist/
scripts/package.sh --version vX.Y.Z   # the release archive + its sha256
tests/packaging.sh  # the archive in a clean container (needs docker)
```

The suites are black-box: they run the built binary with a scratch HOME and a
scratch store. `scripts/test.sh --build` rebuilds first. The build is
`CGO_ENABLED=0 go build`, so the executable links no SQLite library and no
other shared object: it runs on a machine with no Go toolchain and no system
SQLite. `tests/packaging.sh` installs the packed archive into such a container
and asserts the artifact is static; it is a separate command, not part of
`scripts/test.sh`, so the default gate stays offline.

## Releasing

Push a `vX.Y.Z` tag and the release workflow (`.github/workflows/release.yml`)
does the rest: it installs the pinned toolchain, builds the binary, packs the
archive and its sha256, runs the packaging test in a clean container, creates
the release for the tag, uploads the assets, and attaches a build-provenance
attestation (`gh attestation verify` checks it). A `workflow_dispatch` run
builds and tests without publishing; the workflow also installs the published
tag back through mise's `github:` backend in a clean container afterwards.

The archive shape is the one `SPEC.md` §8 fixes:
`skill-log-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz`, holding the static
`skill-log` executable, this project's `LICENSE`, the third-party notices and
the licence texts they point at. `scripts/package.sh` builds it reproducibly,
and `tests/packaging.sh` installs it into a clean container to prove it needs
neither a toolchain nor a system SQLite.

## Command surface

| Command | Purpose |
| --- | --- |
| `add` | Record one invocation and zero or more problems. |
| `show` | Recent rows, their problems, and the cuts: skill, machine, harness, repo, run, unresolved, last. |
| `stats` | Invocation, problem and resolved counts, and problems per invocation, per cut (`--by`). |
| `resolve` | Stamp one local row with the commit that fixed it, by hand. |
| `report` | Name the rows a change fixes: the committed report file, or the trailer in a repo without one. |
| `skills audit` | Report each skill's usage-log state (`ok`, `missing`, `stale`, `edited`, `vendored`). |
| `skills adopt` | Append a block where none is fenced and re-render a stale one; rewrite an `edited` block only with `--force`. |
| `skills template` | Show, seed, reset, or override the user-owned templates; reports when the shipped default moved. |
| `resolve-merged` | The hook's entry point: stamp the rows a landed pull's reports or trailers name. |
| `setup` | Provision the store, the post-merge hook, the report directory and the bundled skills; `--check` verifies. |
| `--version` | Print the release version. |

Every verb in the specification is in the binary; [SPEC.md](SPEC.md) §5 is the
contract each one meets.

Exit codes: `0` success or nothing to do, `1` operational failure, `2` usage.
JSON goes to stdout; one-line diagnostics go to stderr; no tracebacks.

## Contract summary

The normative text is [SPEC.md](SPEC.md) §2; this is a summary, not a second
copy.

- The CLI is the public surface. The store schema and the report format are
  contracts, not APIs.
- A marker is `machine#id`; a marker naming another machine is `foreign`:
  reported, never stamped.
- Reports carry machine names and local ids only, never problem text.
- Generated skill text is owned only inside its fence.

## Documentation

- [SPEC.md](SPEC.md) — the specification: behavior, store, commands, reports,
  resolution, skills, distribution, testing.
- [ADR-0001](docs/adr/0001-mojo-binary-and-sqlite.md) — why a Mojo binary and a
  vendored SQLite binding (superseded by ADR-0004).
- [ADR-0002](docs/adr/0002-explicit-harness-context.md) — explicit harness
  context, adapters, `report`, one store per machine.
- [ADR-0003](docs/adr/0003-module-map.md) — the module map behind the CLI.
- [ADR-0004](docs/adr/0004-go-binary-and-pure-go-sqlite.md) — why a Go binary
  and a pure-Go SQLite driver.
- [CONTEXT.md](CONTEXT.md) — vocabulary: what the terms mean.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — the modules the binary
  includes, and their licences.
- [Issue #1](https://github.com/Dahep/skill-log/issues/1) and
  [issue #3](https://github.com/Dahep/skill-log/issues/3) — the historical
  contracts this specification replaces.

## License

[MIT](LICENSE)
