# skill-log

A local log of agent-skill invocations: one row per run, plus the problems
that cost it, so friction can be counted, attributed to a skill, and closed by
a specific change.

**Status:** build starting. The specification is [SPEC.md](SPEC.md); the
decisions behind it are in [docs/adr/](docs/adr/), and the vocabulary in
[CONTEXT.md](CONTEXT.md). Until the first release, the Python implementation
it replaces is archived verbatim in [`reference/`](reference/README.md): that
tree is the parity ground truth for the port, not the shipped tool.

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

## Install (planned)

```bash
mise use -g github:Dahep/skill-log@1.0.0
skill-log setup --repo ~/dotfiles --skills-dir ~/dotfiles/.agents/skills
```

`setup` provisions the store, the post-merge hook, the repo report directory,
and both bundled skills. `setup --check` verifies the result without writing.

## Build and test

```bash
scripts/build.sh   # dist/skill-log plus dist/lib/, rpath $ORIGIN/lib
scripts/test.sh    # the suites against dist/
```

The suites are black-box: they run the built binary with a scratch HOME and a
scratch store. `scripts/test.sh --build` rebuilds first.

## Command surface

| Command | Purpose |
| --- | --- |
| `add` | Record one invocation and zero or more problems. |
| `show` | Recent rows, their problems, and the cuts: skill, machine, harness, repo, run, unresolved, last. |
| `stats` | Invocation, problem and resolved counts, and problems per invocation, per cut (`--by`). |
| `resolve` | Stamp one local row with the commit that fixed it, by hand. |
| `resolve-merged` | Resolve rows from the commits a pull landed; reports in artifact mode, trailers otherwise. |
| `report` | Name the rows a change fixes: the committed report file, or the trailer in a repo without one. |
| `setup` | Provision or verify the store, hook, report directory, and skills. |
| `skills audit` | Report each skill's usage-log state (`ok`, `missing`, `stale`, `edited`, `vendored`). |
| `skills adopt` | Append a block where none is fenced and re-render a stale one; rewrite an `edited` block only with `--force`. |
| `skills template` | Show, seed, reset, or override the user-owned templates; reports when the shipped default moved. |
| `--version` | Print the release version. |

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
  vendored SQLite binding.
- [ADR-0002](docs/adr/0002-explicit-harness-context.md) — explicit harness
  context, adapters, `report`, one store per machine.
- [ADR-0003](docs/adr/0003-module-map.md) — the module map behind the CLI.
- [CONTEXT.md](CONTEXT.md) — vocabulary: what the terms mean.
- [Issue #1](https://github.com/Dahep/skill-log/issues/1) and
  [issue #3](https://github.com/Dahep/skill-log/issues/3) — the historical
  contracts this specification replaces.

## License

[MIT](LICENSE)
