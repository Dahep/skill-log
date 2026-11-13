#!/usr/bin/env python3
"""Compare two Mojo files for *code* equality, ignoring comments and
docstrings.

Both files are reduced to their code: comments are dropped, docstring
blocks are dropped, and string-literal values are kept verbatim (they are
data).  The reduced forms are compared line by line.

Usage:
    scripts/code-equal.py OLD NEW
    scripts/code-equal.py OLD NEW --quiet
"""

from __future__ import annotations

import sys
from pathlib import Path

QUOTE = '"' * 3
DECL_WORDS = {"def", "fn", "struct", "trait", "alias", "class"}


def previous_code_line(lines: list[str], i: int) -> str | None:
    j = i - 1
    while j >= 0:
        s = lines[j].strip()
        if s == "" or s.startswith("#"):
            j -= 1
            continue
        return s
    return None


def opens_docstring(lines: list[str], i: int) -> bool:
    prev = previous_code_line(lines, i)
    if prev is None:
        return True
    if prev.endswith((":", "->", "(", "=", ",")):
        return True
    head = prev.split(" ")[0].split("(")[0]
    return head in DECL_WORDS


def reduce_source(text: str) -> list[str]:
    """The code of a Mojo source: comments and docstrings removed."""
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("#"):
            i += 1
            continue
        if QUOTE not in line:
            out.append(line)
            i += 1
            continue
        is_doc = opens_docstring(lines, i)
        after = stripped.split(QUOTE, 1)[1]
        if after.count(QUOTE) == 0:
            # The block runs past this line.
            if not is_doc:
                out.append(line)
            i += 1
            while i < len(lines):
                s = lines[i].strip()
                if not is_doc:
                    out.append(lines[i])
                i += 1
                if s.endswith(QUOTE):
                    break
            continue
        if not is_doc:
            out.append(line)
        i += 1
    # Trailing blank lines are noise.
    while out and out[-1].strip() == "":
        out.pop()
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    quiet = "--quiet" in sys.argv
    if len(args) != 2:
        print("usage: code-equal.py OLD NEW", file=sys.stderr)
        return 2
    old = reduce_source(Path(args[0]).read_text())
    new = reduce_source(Path(args[1]).read_text())
    if old == new:
        if not quiet:
            print(f"code identical: {len(old)} code lines")
        return 0
    print("CODE DIFFERS", file=sys.stderr)
    import difflib

    for line in difflib.unified_diff(old, new, args[0], args[1], lineterm="", n=2):
        print(line)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
