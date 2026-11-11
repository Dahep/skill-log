# skill-log

A local log of agent-skill invocations: one row per run, plus the problems
that cost it, so friction can be counted, attributed to a skill, and closed by
a specific change.

**Status:** implementation spec settled ([issue #3](../../issues/3)); build
starting. The behavior contract lives in [issue #1](../../issues/1), and the
implementation decisions are recorded in
[ADR-0001](docs/adr/0001-mojo-binary-and-sqlite.md). Until the first release,
the Python implementation in the dotfiles repo (`bin/skill-log`) is the
reference for behavior.

## What it is

Agent skills end a run by writing one row: when, which skill, model, project,
threads, worktree, and machine. Problems ride as separate rows attached to the
invocation, so a clean run still counts as a denominator and
problems-per-invocation stays measurable.

The store is one SQLite file under the XDG state directory. There is no
daemon and no network except `sync`, which pulls another machine's store over
SSH and merges its rows into an aggregate. Each machine owns its rows; an
aggregate reads them but never resolves them.

A change closes the rows it fixes by committing a report file (or, in repos
that cannot carry one, a marker trailer) naming `machine#id` markers. A
post-merge hook stamps the resolved rows, so the log records when and where
the friction closed.

Reading is a skill, and so is the review: a bundled `skill-friction-review`
skill clusters the logged problems into themes and decides what to fix. It
never marks a row resolved — only the merge hook does that, when the change
lands.

## Install (planned)

```bash
mise use -g github:Dahep/skill-log@1.0.0
skill-log setup --repo ~/dotfiles --skills-dir ~/dotfiles/.agents/skills
```

`setup` provisions the store, the post-merge hook, the repo report directory,
and both bundled skills. `setup --check` verifies the result without writing.

## Command surface

| Command | Purpose |
| --- | --- |
| `add` | Record one invocation and zero or more problems. |
| `show` | Recent rows, filtered by skill, machine, or unresolved state. |
| `stats` | Per-skill (optionally per-model) invocation, problem, and resolved counts. |
| `resolve` | Stamp one local row with the commit that fixed it. |
| `resolve-merged` | Resolve rows from the commits a pull landed; reports in artifact mode, trailers otherwise. |
| `fix` | Write or update the committed report listing the rows a change resolves. |
| `sync` | Pull another machine's store over SSH and merge it. |
| `setup` | Provision or verify the store, hook, report directory, and skills. |
| `skills audit` | Report each skill's usage-log state (`ok`, `missing`, `stale`, `edited`, `legacy`, `unowned`, `vendored`). |
| `skills adopt` | Append missing blocks and re-render stale ones; never touch edited ones without `--force`. |
| `skills template` | Show, seed, reset, or override the user-owned templates. |
| `--version` | Print the release version. |

Exit codes: `0` success or nothing to do, `1` operational failure, `2` usage.
JSON goes to stdout; one-line diagnostics go to stderr; no tracebacks.

## Contracts

- The CLI is the public surface. The store schema and the report format are
  contracts, not APIs.
- A marker is `machine#id` — the machine is required because ids are per
  store. Bare ids and placeholders are refused, never guessed at.
- Reports carry machine names and local ids only, never problem text.
- Per-machine resolution is the core invariant: the owner's store is the only
  writer of its rows, and an aggregate never claims a resolution its owner
  would overwrite.
- Skills carry the reporting instruction as a fenced block rendered from a
  user-owned template. The tool owns the bytes inside the fence and nothing
  outside it.

## Documentation

- [Product spec](../../issues/1) — behavior contract: problem, solution,
  command surface, testing decisions, out-of-scope.
- [Implementation spec](../../issues/3) — Mojo, binary distribution, templates,
  provisioning.
- [ADR-0001](docs/adr/0001-mojo-binary-and-sqlite.md) — why a Mojo binary and a
  vendored SQLite binding.
- [CONTEXT.md](CONTEXT.md) — domain vocabulary and invariants.

## License

[MIT](LICENSE)
