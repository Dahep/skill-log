#!/usr/bin/env python3
"""Count prose lines (docstrings and comments) in the Mojo sources.

Prose = the lines of a docstring block (a run of three double quotes used
as documentation) plus comment-only lines.  String literals that are
*values* are excluded: a quoted block that is not the first statement of a
module, a function body, or a class body is data, and none of its lines
count.

The scan is a single pass that tracks whether a quoted block is a docstring
or a value.  A block is a docstring when the nearest preceding non-blank,
non-comment line ends a declaration header (a line ending in colon, arrow,
open paren, equals, or comma) or is a def/fn/struct/trait/alias header, or
when the block is the first thing in the file.

Usage:
    scripts/prose-count.py            # per-file and total
    scripts/prose-count.py --total    # just the total
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "skill_log"

DECL_WORDS = {"def", "fn", "struct", "trait", "alias", "class"}
QUOTE = '"' * 3


def previous_code_line(lines: list[str], i: int) -> str | None:
    """The nearest preceding line that is not blank and not a comment."""
    j = i - 1
    while j >= 0:
        s = lines[j].strip()
        if s == "" or s.startswith("#"):
            j -= 1
            continue
        return s
    return None


def opens_docstring(lines: list[str], i: int) -> bool:
    """True when the quoted block starting at line i is a docstring."""
    prev = previous_code_line(lines, i)
    if prev is None:
        return True  # first statement in the file: the module docstring
    if prev.endswith((":", "->", "(", "=", ",")):
        return True
    head = prev.split(" ")[0].split("(")[0]
    return head in DECL_WORDS


def count_file(path: Path) -> tuple[int, int, int]:
    """Return (prose_lines, comment_lines, docstring_lines) for one file."""
    lines = path.read_text().splitlines()
    total = 0
    comments = 0
    docstrings = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("#"):
            comments += 1
            total += 1
            i += 1
            continue
        if QUOTE not in line:
            i += 1
            continue

        is_doc = opens_docstring(lines, i)
        rest = stripped
        # The opening delimiter, then either the block ends on this line or
        # it runs to a later closing delimiter.
        after = rest.split(QUOTE, 1)[1] if QUOTE in rest else ""
        if after.count(QUOTE) == 0:
            # Block continues on the following lines.
            if is_doc:
                total += 1
                docstrings += 1
            i += 1
            while i < len(lines):
                s = lines[i].strip()
                if is_doc:
                    total += 1
                    docstrings += 1
                i += 1
                if s.endswith(QUOTE):
                    break
            continue
        # The block opens and closes on this line.
        if is_doc:
            total += 1
            docstrings += 1
        i += 1
    return total, comments, docstrings


def main() -> int:
    args = sys.argv[1:]
    grand = grand_c = grand_d = 0
    rows = []
    for path in sorted(SRC.glob("*.mojo")):
        t, c, d = count_file(path)
        grand += t
        grand_c += c
        grand_d += d
        rows.append((path.name, t, c, d))
    if "--total" in args:
        print(f"{grand} prose lines ({grand_c} comments, {grand_d} docstring)")
        return 0
    width = max((len(r[0]) for r in rows), default=0)
    for name, t, c, d in rows:
        print(f"{name:<{width}}  {t:>6}  (comments {c:>5}, docstrings {d:>5})")
    print(f"{'TOTAL':<{width}}  {grand:>6}  (comments {grand_c:>5}, docstrings {grand_d:>5})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
