#!/usr/bin/env python3
"""Trim the tree's `#` comments down to the ones a reader needs.

A comment survives when the code would otherwise mislead: the rule the
code does not spell out, the value a reader would have to guess, or the
failure contract.  Everything else — section banners, restatements of
the code above, play-by-play — goes.

The keep list is by (module, the run's first line).  A kept comment is
rewritten to at most two lines.

Usage:
    python3 scripts/trim-comments.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "skill_log"


def keep_map() -> dict[tuple[str, str], str | None]:
    """The comments that stay, by (module, the run's first line).

    A `None` value means the run is deleted even though it is listed:
    the list names the run so the deletion is explicit.
    """
    return {
        # The busy-retry budget: the whole attempt is retried, because a
        # lock is retryable and a refusal is not.
        ("store", "The write budget, ported from the reference. Concurrent skill runs log"):
            "The write budget: a whole attempt is retried, because a lock is retryable\n"
            "and a refusal is not.",
        # The column list is the schema: one list builds the DDL, the
        # allow-list, the SELECT lists and the JSON key order.
        ("store", "The invocation table's columns, exactly as ADR-0002 defines them. This"):
            "The column list is the schema: the DDL, the allow-list, the SELECT lists\n"
            "and the JSON key order are all built from it.",
        # The read-only open: the binding opens read-write, so the read
        # path opens the store read-only instead.
        ("store", "The vendored binding opens read-write (it exposes no open flags), so a"):
            None,
        # The statement reset: SQLite answers a bind on a finished
        # statement with SQLITE_MISUSE.
        ("store", "A statement that has reached SQLITE_DONE must be reset before it"):
            "A statement that reached SQLITE_DONE must be reset before it is bound again.",
        # The refusal kinds: a lock is deliberately not one of them.
        ("store", "The refusal kinds, one value per named refusal. A caller compares the"):
            "The refusal kinds: a lock is deliberately not one of them, because a refusal\n"
            "is final and a lock is retryable.",
        # The schema check's foreign answer is final, so it is asked
        # twice.
        ("store", "A concurrent `add` may have committed the schema between"):
            "A concurrent `add` may have committed the schema between those two queries,\n"
            "and the answer \"foreign\" is final, so it is asked once more.",
        # The prepared statement reset in the merged writer.
        ("store", "One prepared statement, reset per row: preparing inside the loop"):
            "One prepared statement, reset per row: preparing inside the loop leaves the\n"
            "earlier one unfinalized, and the COMMIT then fails with SQLITE_MISUSE.",
        # The NUL record framing: NUL cannot appear in a commit message,
        # so it cannot be confused with data.
        ("merged", "A field separator for the git log records, and the record separator"):
            "The record framing: NUL cannot appear in a commit message, so it cannot be\n"
            "confused with data.",
        # The byte-exact fence rewrite.
        ("document", "The content is the bytes between the two fence lines, minus the"):
            "The content is the bytes between the fence lines, minus one newline:\n"
            "stripping exactly one keeps the round trip honest.",
        # The `--problem -` rule: a hook must never block.
        ("add", "`--problem -` reads the text from stdin. On a terminal there is"):
            "`--problem -` reads the text from stdin; on a terminal it refuses, because\n"
            "a hook must never block.",
        # The machine namespaces every marker.
        ("add", "The machine namespaces every marker (`machine#id`). A `#` or a"):
            "The machine namespaces every marker (`machine#id`): a `#` or a control\n"
            "character would make the row unnameable.",
        # The ownership marker is what says the tool wrote the file.
        ("setup", "The ownership marker every generated hook carries, on a line of its"):
            "The ownership marker: it is the one thing that says this tool wrote the file.",
        # The hook mode: git runs a hook only when it is executable, so
        # the file carries its execute bits at creation.
        ("setup", "The mode the generated hook is written with: git runs a hook only when"):
            "The hook's mode: git runs a hook only when it is executable, so the file\n"
            "carries its execute bits at creation.",
        # The `--problem -` rule is in the docstring now.
        ("skills", "The current render is what the fence is compared against. The"):
            None,
        # The moved default is named by the function above.
        ("skills", "A shipped default that moved since the user copy was seeded is"):
            None,
        # The resolved binary path is the other half of the current render.
        ("skills", "The resolved binary path is the other half of the current render:"):
            None,
        # The findings go to stdout even when the exit code says otherwise.
        ("skills", "The findings are the answer and go to stdout even when the"):
            None,
        # A moved default is its own failure.
        ("skills", "A moved default is its own failure: the directory may be"):
            None,
        # The foreign answer is final, so it is asked once more.
        ("store", "A concurrent `add` may have committed the schema between"):
            None,
        # A string is a key only when a colon follows it.
        ("adapters", "A string is a key only when a colon follows it. A string"):
            None,
        # The scp-style remote.
        ("detect", "An scp-style remote: `git@host:owner/repo.git`."):
            None,
        # The markdown list item.
        ("document", "A markdown list item whose label ends in a colon introduces what"):
            None,
        # The List cannot be walked with `for`.
        ("help", "Indexed, not iterated: a `List` of non-Copyable elements cannot be"):
            None,
    }


def trim(text: str, module: str, keep: dict[tuple[str, str], str | None]) -> str:
    """The text with every comment run deleted or rewritten.

    A `#` line inside a multi-line string value is data, not a comment:
    the bundled skill, the report README, the hook script and the
    shipped templates all carry one.  The scan tracks the string
    literals so those lines are never touched.
    """
    lines = text.splitlines()
    out: list[str] = []
    in_value = False
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if in_value:
            out.append(lines[i])
            if stripped.endswith('"""'):
                in_value = False
            i += 1
            continue
        if stripped.startswith("#"):
            # The run: this line and every following comment line.
            j = i
            while j + 1 < len(lines) and lines[j + 1].strip().startswith("#"):
                j += 1
            body = stripped.lstrip("#").strip()
            key = (module, body)
            if key in keep and keep[key] is not None:
                indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
                for l in keep[key].rstrip("\n").split("\n"):
                    out.append((indent + "# " + l).rstrip())
            i = j + 1
            continue
        out.append(lines[i])
        # The quoted blocks: a docstring opens and closes one, a value
        # opens with `return """` and closes at the last `"""`.  A
        # docstring's closing line carries the text before the
        # delimiter, so the opening line is what tells them apart.
        if '"""' in stripped:
            if stripped.startswith('"""'):
                # A docstring. One line, or it runs to the closing line.
                if stripped.count('"""') < 2:
                    j = i + 1
                    while j < len(lines) and not lines[j].strip().endswith('"""'):
                        j += 1
                    out.extend(lines[i + 1 : j + 1])
                    i = j + 1
                    continue
            else:
                # A value: the block runs to the next closing delimiter.
                rest = stripped.split('"""', 1)[1]
                if '"""' not in rest:
                    in_value = True
        i += 1
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out) + "\n"


def main() -> int:
    keep = keep_map()
    for path in sorted(SRC.glob("*.mojo")):
        text = path.read_text()
        path.write_text(trim(text, path.stem, keep))
    print("comments trimmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
