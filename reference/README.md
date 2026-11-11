# reference — the report-era implementation, kept verbatim

This directory holds the **report-era** `skill-log` implementation: the Python
CLI, its bash harness, the skill text and the usage-log boilerplate, as they
existed when the report-directory mode landed. It is the parity ground truth
for #21 (the ported harness comparison) and the behaviour reference while the
Mojo binary is built.

## The copies are verbatim

Every file here was copied byte-for-byte from the source repository. Nothing
was reworded, reformatted, reindented or line-ending-changed. `SHA256SUMS`
holds the digest of each copy, so "never edited" is checkable at any time:

```
cd reference && sha256sum -c SHA256SUMS
```

The copies can be re-verified against the source repository without checking
the branch out:

```
git -C /home/dherrmann/dotfiles show t3/e53b1745:bin/skill-log | cmp - reference/skill-log
```

## Source

| | |
|---|---|
| Repository | `/home/dherrmann/dotfiles` (local; not published) |
| Branch | `t3/e53b1745` |
| Tip commit | `13ba6b37d4d1cf95663347bff0c492ef9fe32b83` — 2026-11-10 — "docs: spec the skill-log project extraction" |
| Implementation commit | `4b393f0e50b51496ee4522b144bc610cd624030d` — 2026-11-10 — "skill-log: report fixes as a committed .skill-log/fixes file" |

All five files were read from the **tip** commit `13ba6b3`; the implementation
commit `4b393f0` is where the report-directory mode itself landed, and is
recorded here because it is the change the reference exists to preserve.

## What is in here

| File | Source path | What it is |
|---|---|---|
| `skill-log` | `bin/skill-log` | The report-era Python CLI. It has `fix`, `resolve-merged` and artifact (report-directory) mode. |
| `test-skill-log.sh` | `scripts/test-skill-log.sh` | The bash harness that exercises it. |
| `SKILL.md` | `.agents/skills/skill-log/SKILL.md` | The skill text of that era. |
| `usage-log.md` | `.agents/skills/create-skill/references/usage-log.md` | The usage-log boilerplate adopted into skills. |
| `report-dir-README.md` | `.skill-log/README.md` | The README of the report directory. Renamed on copy so it cannot be mistaken for this repository's own report directory. |

## This copy is not built, not shipped, not imported

- **Not built.** `scripts/build.sh` compiles only `src/` and links only
  `vendor/`. Nothing under `reference/` is compiled, copied into `build/`, or
  staged into `dist/`.
- **Not shipped.** The release archive stages only `dist/skill-log` and
  `dist/lib/`. `reference/` is not part of the release archive.
- **Not imported.** Nothing in `src/` reads, imports, executes or embeds any
  file in this directory. `reference/` is inert data.

`scripts/build.sh` stages `src/`/`vendor/` output only, and
`tests/smoke.sh` refuses to run if `reference/` ever appears in `dist/`.

## Never edited

The copies are never edited. A change to the reference is a change to the
history, not to these files: the ported harness lives separately in `tests/`,
and the parity comparison in #21 reads both sides without touching this
directory.
