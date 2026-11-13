#!/usr/bin/env python3
"""Reduce every multi-line docstring in the tree to its first line.

The first line is the sentence the name does not already say; the rest
is prose the code carries.  The exceptions — the docstrings whose extra
paragraphs carry a contract a reader cannot get from the code — are
listed in `KEEP` with the exact text that replaces them.

Usage:
    python3 scripts/shorten-docstrings.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "skill_log"

QUOTE = '"' * 3

# The characters a sentence can end with.
TERMINAL = ".!?\"`)"


def _is_sentence(text: str) -> bool:
    """True when the text ends like a finished sentence."""
    return bool(text) and text[-1] in TERMINAL


def keep_map() -> dict[tuple[str, str], str]:
    """The docstrings that keep their extra paragraph, and its text.

    The key is (module, the docstring's first line).  The value is the
    text that replaces the whole block: the first line, then the
    paragraph that carries the contract, indented for the docstring.
    """
    return {
        # The fence is the only provenance there is: everything outside
        # it is user-owned.
        ("document", "The document: the fenced usage-log block, parsed and classified."):
            "The document: the fenced usage-log block, parsed and classified.\n"
            "\n"
            "The fence is the only provenance there is. Everything outside it is\n"
            "user-owned: the tool never reads, matches, rewrites or deletes a byte\n"
            "outside the fence — not even with `--force`.",
        # The precedence chain, applied per field.
        ("add", "One field of the row, by ADR-0002's precedence."):
            "One field of the row, by ADR-0002's precedence.\n"
            "\n"
            "The explicit flag wins, then the field's `SKILL_LOG_*` variable, then\n"
            "the enabled adapter's value, then the built-in detection. A blank at\n"
            "every level means the field is unknown, and unknown is written as an\n"
            "empty string.",
        # The path may carry any word the taxonomy uses.
        ("store", "`message` with the store's own path removed."):
            "`message` with the store's own path removed.\n"
            "\n"
            "The binding puts the path it was given into its own wording, and a path\n"
            "can contain any word the taxonomy uses, so the classification is made\n"
            "on what the binding appended *after* the path, never on the path.",
        # The refusals are values, never words inside a message.
        ("store", "A store that was refused, and why."):
            "A store that was refused, and why.\n"
            "\n"
            "The kind is a value rather than a word inside a message: a path the\n"
            "caller named can contain any word at all, so a scheme that re-derived\n"
            "the kind from the message text would let the path decide the refusal.",
        # A refusal is final; a lock is retryable.
        ("store", "The named failure for a SQLite error on the write path."):
            "The named failure for a SQLite error on the write path.\n"
            "\n"
            "The same taxonomy the read path has (SPEC §3). The named ones do not\n"
            "carry SQLite's wording, so a caller never has to read it to learn what\n"
            "happened.",
        # The read path never writes.
        ("store", "Open an existing store for reading."):
            "Open an existing store for reading.\n"
            "\n"
            "`db` is `None` when the file does not exist: a read never creates the\n"
            "state directory, the file, or an empty database. The vendored binding\n"
            "opens read-write, so the read path opens the store read-only instead —\n"
            "a file that is not there is a failure and never a new file.",
        # A whole attempt is retried inside the budget.
        ("store", "Write one invocation and its problems, atomically."):
            "Write one invocation and its problems, atomically.\n"
            "\n"
            "One transaction covers the invocation row and every problem row: a\n"
            "failed write leaves nothing behind. A BUSY/LOCKED failure is retried as\n"
            "a whole attempt inside the write budget, because a concurrent skill run\n"
            "holding the lock costs milliseconds, not the command.",
        # The newest marker wins; a foreign machine is never stamped.
        ("store", "Decide each located marker: stamp, unchanged, or skip with a reason."):
            "Decide each located marker: stamp, unchanged, or skip with a reason.\n"
            "\n"
            "Pure: no git, no clock, no store. The newest marker wins, because the\n"
            "scan walks commits newest first. A row stamped with the *same* commit is\n"
            "unchanged; a row stamped with a *different* commit is restamped. A marker\n"
            "whose machine is not this host's spelling is foreign and is never stamped\n"
            "(SPEC §2).",
        # The counting rule.
        ("store", "Count the invocations and problems per value of `column`."):
            "Count the invocations and problems per value of `column`.\n"
            "\n"
            "`COUNT(DISTINCT i.id)` is the denominator and the only honest count: the\n"
            "LEFT JOIN produces one line per problem, so `COUNT(*)` would count\n"
            "problems and `COUNT(DISTINCT i.id)` counts runs.",
        # The group count's two denominators differ by design.
        ("store", "One line of the stats table: a group's key and its four counts."):
            "One line of the stats table: a group's key and its four counts.\n"
            "\n"
            "`with_problems` counts invocations that have at least one problem, and\n"
            "`problems` counts problem rows. They differ by design: the rate's\n"
            "denominator is invocations, so a run with two findings is one run and\n"
            "two problems.",
        # The shell-quoting rule.
        ("detect", "`text` as one single-quoted shell word."):
            "`text` as one single-quoted shell word.\n"
            "\n"
            "A path the caller named reaches a shell command string, so it is quoted\n"
            "the one way a POSIX shell always reads back literally: single quotes,\n"
            "with an embedded single quote closed, escaped and re-opened.",
        # The scanner tracks nesting.
        ("adapters", "The value of a string field at the top level of a JSON object."):
            "The value of a string field at the top level of a JSON object.\n"
            "\n"
            "A small targeted scanner, not a JSON parser: the only shape this tool\n"
            "reads is opencode's `{\"id\":\"...\",\"providerID\":\"...\"}`. The scan\n"
            "tracks nesting, so a key spelled inside a nested object never answers\n"
            "for the top-level one.",
        # A command line's placeholders are quoted; a prose line's are not.
        ("document", "`template` with every `<name>` and `<command>` replaced."):
            "`template` with every `<name>` and `<command>` replaced.\n"
            "\n"
            "The one exception is a *command line*: there the substituted value is\n"
            "shell-quoted, because the reader copies that line out of the block and\n"
            "runs it. The prose lines keep the plain substitution.",
        # The vendor stamp's shape.
        ("document", "True when the document carries the vendor stamp."):
            "True when the document carries the vendor stamp.\n"
            "\n"
            "The scan is line-based and prefix-based on purpose — no YAML parser is\n"
            "needed to recognise the two-line shape: a `source:` key at the start of\n"
            "a line inside a frontmatter `metadata:` block is the stamp.",
        # The atomic replace and its exclusive temporary.
        ("files", "Replace `path` with `text`, atomically, at exactly `mode`."):
            "Replace `path` with `text`, atomically, at exactly `mode`.\n"
            "\n"
            "The temporary lives beside the target — a rename across filesystems is a\n"
            "copy, not an atomic swap — and is created with `O_EXCL`, so a file\n"
            "already at that name is never followed. The mode is set on the\n"
            "descriptor before the rename, so the replacement is never visible at the\n"
            "wrong permissions.",
        # The owner's execute bit is the one that matters.
        ("files", "True when the *owner* of `path` may execute it."):
            "True when the *owner* of `path` may execute it.\n"
            "\n"
            "The owner's bit is the one that matters, not \"somebody's\": git runs the\n"
            "hook as the user who pulled, and the installer wrote the file as that\n"
            "user. A file that cannot be stat'ed is not executable.",
        # The hostname failure is not a blank.
        ("context", "This machine's hostname."):
            "This machine's hostname.\n"
            "\n"
            "A hostname that cannot be read is an error, not an empty string: the\n"
            "machine namespaces the store's markers, so a row without one is a row\n"
            "nothing can resolve.",
        # The clock comes from SQLite, not libc.
        ("context", "The writer's local wall clock as ISO 8601 with its offset."):
            "The writer's local wall clock as ISO 8601 with its offset.\n"
            "\n"
            "`SKILL_LOG_NOW`, when set, is the stamp: the test-only clock injection\n"
            "(SPEC §9) is consulted first and returned as written.",
        # The trailer grammar is line-based and prefix-based.
        ("merged", "Every marker the body's `Skill-log-Fix:` lines carry, in body order."):
            "Every marker the body's `Skill-log-Fix:` lines carry, in body order.\n"
            "\n"
            "The scan is line-based and prefix-based, like the marker grammar itself.\n"
            "A line may hold several comma-separated markers, so the line's value is\n"
            "split into its pieces here.",
        # The last-trailer-block rule loses earlier blocks.
        ("merged", "The values the body carries that the trailer parser did not see."):
            "The values the body carries that the trailer parser did not see.\n"
            "\n"
            "Git's last-trailer-block rule returns the markers of the final block\n"
            "only, so a body with two marker blocks loses the earlier one. Every\n"
            "value the parser did not return is reported, not dropped.",
        # The slug rule.
        ("report", "The report file's name for a branch: lowercase, safe, truncated."):
            "The report file's name for a branch: lowercase, safe, truncated.\n"
            "\n"
            "Every run of characters outside `[a-z0-9._-]` becomes one `-`, leading\n"
            "and trailing `.`/`-` are dropped, and the result is cut to `MAX_SLUG`.",
        # The report is markers only.
        ("report", "The markers the selectors name, split into pending and resolved."):
            "The markers the selectors name, split into pending and resolved.\n"
            "\n"
            "`--id` rows are looked up one by one, so a missing id is named even when\n"
            "the other selectors would have excluded it. A query with no id list\n"
            "reads every matching row, with no hidden limit.",
        # A line that is not a marker is reported, not dropped.
        ("report", "The markers in a report's text, plus any line that is not one."):
            "The markers in a report's text, plus any line that is not one.\n"
            "\n"
            "A report is tool-owned: every non-blank line is a marker. A line that is\n"
            "not one is reported with its position rather than dropped.",
        # The empty filter value is a mistake.
        ("show", "Read `show`'s flags."):
            "Read `show`'s flags.\n"
            "\n"
            "An unknown flag, a missing value or an empty filter value is a usage\n"
            "error, raised as a `usage` marker the caller turns into exit 2.",
        # The ratio is integer arithmetic.
        ("stats", "Problems per invocation, to two decimals, in integer arithmetic."):
            "Problems per invocation, to two decimals, in integer arithmetic.\n"
            "\n"
            "Rounding a float here would let the table and the JSON disagree at the\n"
            "last digit on some machine. The same string feeds both renderings.",
        # The template's placeholders.
        ("skills", "Render `template` for one skill into a fenced block."):
            "Render `template` for one skill into a fenced block.\n"
            "\n"
            "The template source is hashed as-is (the hash is of the *source*, so a\n"
            "copy in the user directory and a shipped default with the same bytes\n"
            "agree). `validate_template` is the caller's job.",
        # The install answer's four questions.
        ("setup", "One skill's install answer, as `name:verdict` with its reason."):
            "One skill's install answer, as `name:verdict` with its reason.\n"
            "\n"
            "Is it there at all? Is it this version's install? Does the stamp match?\n"
            "Under `--check` nothing is written. A vendored copy is skipped entirely.",
        # The store verdict.
        ("setup", "The store's verdict: `create`, or `verify` under `--check`."):
            "The store's verdict: `create`, or `verify` under `--check`.\n"
            "\n"
            "The verdict comes from the store's own path, never from inspecting\n"
            "SQLite here. A refused store is drift with the refusal's own named\n"
            "message: setup creates a store and never migrates one.",
        # The marker is required for the read to be worth anything.
        ("settings", "The path of this binary, resolved: `<command>`'s value."):
            "The path of this binary, resolved: `<command>`'s value.\n"
            "\n"
            "The resolved path is what the rendered block names, so a binary that\n"
            "moved makes every block an older render.",
        # The template resolution order.
        ("skills", "The effective template `name`, resolved over the shipped default."):
            "The effective template `name`, resolved over the shipped default.\n"
            "\n"
            "The source is the first of the chain that has the file: the resolved\n"
            "directory, then the shipped default embedded in the binary. `moved` is\n"
            "set when the file came from the user directory and the shipped default's\n"
            "hash differs from the seeded-from hash on record.",
        # The `--problem -` rule.
        ("stdin", "One line from standard input, without its newline."):
            "One line from standard input, without its newline.\n"
            "\n"
            "A hook pipes one line into `add --problem -`, so this reads exactly one\n"
            "line and never blocks on a terminal.",
        # The verb tree.
        ("verb", "One verb's metadata, as shown by `--help`."):
            "One verb's metadata, as shown by `--help`.\n"
            "\n"
            "The help renderer reads the table like any other verb, so a\n"
            "subcommand's block is the common block and there is no second renderer\n"
            "to keep in step.",
        # The JSON key order.
        ("json", "One JSON object, built in the order its keys are handed in."):
            "One JSON object, built in the order its keys are handed in.\n"
            "\n"
            "The order is the caller's, and the caller is the schema: the row's\n"
            "fields land in the order the store's column list declares.",
        # The read-only reader.
        ("opendb", "A `Database` opened read-only, or a failure naming the path."):
            "A `Database` opened read-only, or a failure naming the path.\n"
            "\n"
            "The vendored binding opens read-write, so a read-only open is reached\n"
            "through SQLite's own flags: a file that is not there is a failure and\n"
            "never a new file.",
        # The document's states.
        ("document", "The document's state, as one of the five names."):
            "The document's state, as one of the five names.\n"
            "\n"
            "The five states are distinct on purpose: a hand-edited block (`edited`)\n"
            "and an older render (`stale`) call for different actions.",
        # The adoption actions.
        ("skills", "Make one skill's document conform, and say what happened."):
            "Make one skill's document conform, and say what happened.\n"
            "\n"
            "`missing` is appended to, `stale` rewritten, `edited` rewritten only\n"
            "with `--force` and otherwise refused, `ok` is left `unchanged`, and\n"
            "`vendored` is `skipped` entirely. The write is the `document` module's\n"
            "splice, so no byte outside the fence can change.",
        # The audit's render comparison.
        ("skills", "One skill's state, from its `SKILL.md`."):
            "One skill's state, from its `SKILL.md`.\n"
            "\n"
            "The current render is the one this skill would get now: the template\n"
            "rendered for *this* skill's name and the resolved binary path. A block\n"
            "that names a different skill or a different binary is `stale`.",
        # The moved-default note.
        ("skills", "The one line that names a moved shipped default, or \"\"."):
            "The one line that names a moved shipped default, or \"\".\n"
            "\n"
            "SPEC §7: a shipped default that moved since the user copy was seeded is\n"
            "named, with the two commands that adopt it. Only a human runs those.",
    }


def shorten(text: str, module: str, keep: dict[tuple[str, str], str]) -> str:
    """The text with every multi-line docstring reduced to its first line."""
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    in_value = False
    while i < len(lines):
        stripped = lines[i].strip()
        if in_value:
            out.append(lines[i])
            if stripped.endswith(QUOTE):
                in_value = False
            i += 1
            continue
        if stripped.startswith(QUOTE):
            body = stripped[len(QUOTE):].strip()
            if body.endswith(QUOTE):
                body = body[: -len(QUOTE)].strip()
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
            # The end of the block.
            if stripped.endswith(QUOTE) and stripped.count(QUOTE) >= 2:
                j = i
            else:
                j = i + 1
                while j < len(lines) and not lines[j].strip().endswith(QUOTE):
                    j += 1
                if j >= len(lines):
                    j = len(lines) - 1
            key = (module, body)
            if key in keep:
                body_text = keep[key]
                block = body_text.split("\n")
                out.append(f"{indent}{QUOTE}{block[0]}")
                for l in block[1:-1]:
                    out.append(indent + l if l else "")
                # The closing delimiter goes on its own line, the way the
                # tree's other multi-line docstrings do.
                out.append(f"{indent}{block[-1]}")
                out.append(f"{indent}{QUOTE}")
            else:
                # A first line that is a sentence fragment needs the
                # line that completes it: the sentence is the docstring.
                text = body
                k = i + 1
                while k <= j and not _is_sentence(text):
                    nxt = lines[k].strip()
                    if nxt.endswith(QUOTE):
                        nxt = nxt[: -len(QUOTE)].strip()
                    if not nxt:
                        k += 1
                        continue
                    text = text + " " + nxt
                    k += 1
                if not _is_sentence(text):
                    text = body
                out.append(f"{indent}{QUOTE}{text}{QUOTE}")
            i = j + 1
            continue
        out.append(lines[i])
        if QUOTE in stripped and not stripped.startswith(QUOTE):
            rest = stripped.split(QUOTE, 1)[1]
            if QUOTE not in rest:
                in_value = True
        i += 1
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out) + "\n"


def main() -> int:
    keep = keep_map()
    for path in sorted(SRC.glob("*.mojo")):
        text = path.read_text()
        path.write_text(shorten(text, path.stem, keep))
    print("docstrings shortened")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
