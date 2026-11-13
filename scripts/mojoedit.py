#!/usr/bin/env python3
"""Rewrite docstrings and comments in a Mojo file by rule.

The rules are stated in a small edit list embedded in the caller, not
here: this module only knows how to replace a docstring block or a
comment run with new text, matched by the text that follows (or precedes)
it.

Usage (as a library):
    from mojoedit import rewrite
    rewrite(path, edits)
"""

from __future__ import annotations

import re
from pathlib import Path

QUOTE = '"' * 3


def find_docstring(lines: list[str], start: int) -> tuple[int, int]:
    """The (start, end) line range of the docstring opening at `start`.

    The opening line holds one quote run; the closing line holds the
    other.  A one-line docstring holds both.
    """
    i = start
    n = len(lines)
    while i < n:
        s = lines[i].strip()
        if s.endswith(QUOTE):
            return start, i
        i += 1
    raise ValueError(f"no closing delimiter from line {start + 1}")


def replace_docstring(text: str, anchor: str, new: str) -> str:
    """Replace the docstring block that starts the line containing
    `anchor`.

    `anchor` is the first line of the docstring (its opening line, minus
    the leading whitespace and the opening quote run).  `new` is the
    replacement text: either a single line, or a block already indented
    the way the file indents it.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith(QUOTE):
            continue
        body = stripped[len(QUOTE):].strip()
        if body.endswith(QUOTE):
            body = body[: -len(QUOTE)].strip()
        if body != anchor:
            continue
        start, end = find_docstring(lines, i)
        indent = line[: len(line) - len(line.lstrip())]
        if "\n" not in new:
            replacement = [f"{indent}{QUOTE}{new}{QUOTE}"]
        else:
            replacement = [indent + l if l else "" for l in new.split("\n")]
        lines[start : end + 1] = replacement
        return "\n".join(lines) + "\n"
    raise ValueError(f"docstring not found: {anchor!r}")


def replace_comment(text: str, anchor: str, new: str) -> str:
    """Replace the comment run whose first line is `anchor`."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        body = stripped.lstrip("#").strip()
        if body != anchor:
            continue
        indent = line[: len(line) - len(line.lstrip())]
        j = i
        while j + 1 < len(lines) and lines[j + 1].strip().startswith("#"):
            j += 1
        replacement = []
        for l in new.split("\n"):
            replacement.append(f"{indent}# {l}".rstrip())
        lines[i : j + 1] = replacement
        return "\n".join(lines) + "\n"
    raise ValueError(f"comment not found: {anchor!r}")


def delete_docstring(text: str, anchor: str) -> str:
    """Delete the docstring block that starts the line containing
    `anchor`, and the blank line that follows it.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith(QUOTE):
            continue
        body = stripped[len(QUOTE):].strip()
        if body.endswith(QUOTE):
            body = body[: -len(QUOTE)].strip()
        if body != anchor:
            continue
        start, end = find_docstring(lines, i)
        del lines[start : end + 1]
        # Drop one following blank line so the file keeps its shape.
        if start < len(lines) and lines[start].strip() == "":
            del lines[start]
        return "\n".join(lines) + "\n"
    raise ValueError(f"docstring not found: {anchor!r}")


def delete_comment(text: str, anchor: str) -> str:
    """Delete the comment run whose first line is `anchor`."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        body = stripped.lstrip("#").strip()
        if body != anchor:
            continue
        j = i
        while j + 1 < len(lines) and lines[j + 1].strip().startswith("#"):
            j += 1
        del lines[i : j + 1]
        return "\n".join(lines) + "\n"
    raise ValueError(f"comment not found: {anchor!r}")
