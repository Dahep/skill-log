#!/usr/bin/env python3
"""Apply the comment-minimization edits to the leaf modules.

Each entry is (file, anchor, new_text) for a docstring or comment that
is replaced, and (file, anchor, None) for one that is deleted outright.
The anchors are the first line of the docstring or of the comment run.

The prose that is kept is the prose the code would otherwise mislead
without: a rule the code does not spell out, a value the reader would
have to guess, or a failure contract.

Usage:
    python3 scripts/leaf-edits.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mojoedit import replace_comment, replace_docstring  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "skill_log"

# (module, anchor, replacement or None)
EDITS: list[tuple[str, str, str | None]] = [
    # ---------------------------------------------------------- adapters
    ("adapters", "The adapter seam: opt-in code that fills context from a known harness.",
     "The adapter seam: opt-in code that fills context from a known harness."),
    ("adapters", "What an enabled adapter filled.",
     "What an enabled adapter filled.\n\n    Every field is a string; an empty one means the adapter\n    did not fill it, or that it failed."),
    ("adapters", "The adapters to run: the flag's names plus the variable's.",
     "The adapters to run: the flag's names plus the variable's.\n\n    Both sources take a comma-separated list. Duplicates are\n    harmless, so the list is not deduplicated here."),
    ("adapters", "The index just past the closing quote of the string opening at `at`.",
     "The index just past the closing quote of the string opening at `at`.\n\n    `-1` when the string never closes."),
    ("adapters", "The value of a string field at the top level of a JSON object.",
     "The value of a string field at the top level of a JSON object.\n\n    A small targeted scanner, not a JSON parser: the only shape this\n    tool reads is opencode's `{\"id\":\"...\",\"providerID\":\"...\"}`. The\n    scan tracks nesting, so a key spelled inside a nested object never\n    answers for the top-level one."),
    ("adapters", "An opencode model value as `provider/id`.",
     "An opencode model value as `provider/id`.\n\n    A value that is not that shape is passed through unchanged."),
    ("adapters", "The path of opencode's session store.",
     "The path of opencode's session store.\n\n    The file is never created: the adapter checks that it exists\n    before it opens it."),
    ("adapters", "The model of an opencode session, or an empty string.",
     "The model of an opencode session, or an empty string.\n\n    The session store is read read-only; a missing file, a changed\n    schema, an absent row — every one of them is an empty string."),
    ("adapters", "Run the enabled adapters and collect what they filled.",
     "Run the enabled adapters and collect what they filled.\n\n    An unknown adapter name is ignored: enabling an adapter this\n    binary does not know must not fail the write."),
    # ----------------------------------------------------------- context
    ("context", "The writer's context: when it happened, and on which machine.",
     "The writer's context: when it happened, and on which machine."),
    ("context", "The UTC offset as `+HH:MM` or `-HH:MM`.",
     "The UTC offset as `+HH:MM` or `-HH:MM`."),
    ("context", "The writer's local wall clock as ISO 8601 with its offset.",
     "The writer's local wall clock as ISO 8601 with its offset."),
    ("context", "This machine's hostname.",
     "This machine's hostname.\n\n    A hostname that cannot be read is an error, not an empty string:\n    the machine namespaces the store's markers, so a row without one\n    is a row nothing can resolve."),
    # ------------------------------------------------------------ detect
    ("detect", "Built-in detection: the facts a row carries when nobody says otherwise.",
     "Built-in detection: the facts a row carries when nobody says otherwise."),
    ("detect", "`text` as one single-quoted shell word.",
     "`text` as one single-quoted shell word.\n\n    A path the caller named reaches a shell command string, so it is\n    quoted the one way a POSIX shell always reads back literally."),
    ("detect", "A remote URL with any credentials removed.",
     "A remote URL with any credentials removed.\n\n    An scp-style remote (`git@host:owner/repo.git`) is returned\n    unchanged: its `git` is the login name in the host position."),
    ("detect", "The repository name an origin URL names.",
     "The repository name an origin URL names.\n\n    The last path segment, without the `.git` suffix."),
    ("detect", "The repository the named worktree belongs to.",
     "The repository the named worktree belongs to.\n\n    Empty when `top` is not a git working tree. A path that is not a\n    checkout names no repository, and one is never invented from the\n    directory's name alone."),
    ("detect", "The T3 project grouping of a worktree.",
     "The T3 project grouping of a worktree.\n\n    The first path segment under `$T3CODE_HOME/worktrees/`, or an empty\n    string when the worktree is not under it."),
    # ---------------------------------------------------------- document
    ("document", "The document: the fenced usage-log block, parsed and classified.",
     "The document: the fenced usage-log block, parsed and classified."),
    ("document", "One fenced usage-log block, as `parse` found it.",
     "One fenced usage-log block, as `parse` found it.\n\n    `start` and `end` are byte offsets into the document. `content` is\n    the text strictly between the two fence lines, without their\n    trailing newline."),
    ("document", "A document split at its fence: what is before, the block, what is",
     "A document split at its fence: what is before, the block, what is\n    after.\n\n    `block` is `None` when the document has no fenced block; `before` is\n    then the whole text and `after` is empty."),
    ("document", "A rendered block: its full fenced text and the two hashes.",
     "A rendered block: its full fenced text and the two hashes."),
    ("document", "Render `template` for one skill into a fenced block.",
     "Render `template` for one skill into a fenced block.\n\n    The template source is hashed as-is (the hash is of the *source*,\n    so a copy in the user directory and a shipped default with the\n    same bytes agree)."),
    ("document", "`template` with every `<name>` and `<command>` replaced.",
     "`template` with every `<name>` and `<command>` replaced.\n\n    A command line's placeholders are shell-quoted; a prose line's are\n    not — see `is_command_line` for how the two are told apart."),
    ("document", "True when the line is a command line of the rendered block.",
     "True when the line is a command line of the rendered block.\n\n    A command line is one that *starts* a command: the placeholder is\n    the first thing on the line, after the indentation, or it follows a\n    markdown list item's label."),
    ("document", "True when `placeholder` sits next to a quote character.",
     "True when `placeholder` sits next to a quote character.\n\n    The tool quotes a placeholder's value with single quotes, and a\n    template's own double quotes around the placeholder would nest the\n    two, so the value would reach the shell where a shell expands it."),
    ("document", "Refuse a template whose placeholders are wrong, by name.",
     "Refuse a template whose placeholders are wrong, by name.\n\n    `usage-log.md` needs `<name>` and an invocation of `<command> add`;\n    `skill-friction-review.md` needs `<command>`. A placeholder may not\n    sit next to a quote character."),
    ("document", "Split `text` at its fence.",
     "Split `text` at its fence.\n\n    Only the first block is recognised: a second fenced block is not\n    this tool's, and treating it as after-text keeps the\n    never-touch-outside-the-fence rule honest."),
    # ----------------------------------------------------------- errors
    ("errors", "The one error and exit path.",
     "The one error and exit path."),
    ("errors", "What a handler returns: text to print, or a failure to report.",
     "What a handler returns: text to print, or a failure to report.\n\n    A handler never writes to a stream. A usage failure carries the\n    usage block in `usage`: it is printed on stderr so stdout stays\n    empty."),
    ("errors", "Write the single stderr line this failure is allowed.",
     "Write the single stderr line this failure is allowed.\n\n    Every control character in the message becomes a space: the\n    contract is one line, not one per control character."),
    # --------------------------------------------------------------- ffi
    ("ffi", "The C ABI seam: `dlopen`'s partner, spelled once.",
     "The C ABI seam: `dlopen`'s partner, spelled once."),
    ("ffi", "Look up a C-ABI symbol as a plain callable value.",
     "Look up a C-ABI symbol as a plain callable value.\n\n    A symbol the library does not export is an error: a silent no-op\n    would misreport every call after it."),
    # ------------------------------------------------------------- files
    ("files", "Reading and atomically replacing a small text file.",
     "Reading and atomically replacing a small text file."),
    ("files", "A NUL-terminated copy of `text`.",
     "A NUL-terminated copy of `text`."),
    ("files", "`path` as one absolute, symlink-resolved path, or \"\".",
     "`path` as one absolute, symlink-resolved path, or \"\".\n\n    Nothing raises: resolution is best-effort, and a name the\n    filesystem cannot resolve is still a usable command."),
    ("files", "True when the *owner* of `path` may execute it.",
     "True when the *owner* of `path` may execute it.\n\n    The owner's bit is the one that matters, not \"somebody's\": git runs\n    the hook as the user who pulled, and the installer wrote the file\n    as that user."),
    ("files", "Replace `path` with `text`, atomically, at exactly `mode`.",
     "Replace `path` with `text`, atomically, at exactly `mode`.\n\n    The temporary lives beside the target — a rename across filesystems\n    is a copy, not an atomic swap — and is created with `O_EXCL`, so a\n    file already at that name is never followed. The mode is set on the\n    descriptor before the rename, so the replacement is never visible at\n    the wrong permissions."),
    # ------------------------------------------------------------- flags
    ("flags", "Reading a flag's value, once.",
     "Reading a flag's value, once."),
    ("flags", "The value of `flag`, which the verb must have declared.",
     "The value of `flag`, which the verb must have declared.\n\n    The check is here, at the one place every verb reads a value, so a\n    flag the parser handles but the declaration does not name is caught\n    at once."),
    # --------------------------------------------------------------- git
    ("git", "The one git seam.",
     "One seam for every git command the tool runs."),
    # -------------------------------------------------------------- hash
    ("hash", "The stable document hash.",
     "The one hash the tool uses."),
    # -------------------------------------------------------------- help
    ("help", "The one help renderer.",
     "One renderer for every level of the verb tree."),
    # -------------------------------------------------------------- json
    ("json", "A hand-rolled JSON writer.",
     "The one JSON writer."),
    # -------------------------------------------------------------- main
    ("main", "The entry point.",
     "The entry point: parse, dispatch, report."),
    # ----------------------------------------------------------- markers
    ("markers", "The marker grammar: `machine#id`.",
     "The marker grammar: `machine#id`."),
    # ------------------------------------------------------------ opendb
    ("opendb", "A read-only SQLite reader.",
     "Opening a store: read-write, or read-only."),
    # ---------------------------------------------------------- registry
    ("registry", "The verb registry: one table entry per verb.",
     "The verb registry: one table, one lookup."),
    # ------------------------------------------------------------ render
    ("render", "The row's JSON shape, in one place.",
     "Rendering a row: the table's cells and the JSON shape."),
    # ---------------------------------------------------------- settings
    ("settings", "Where the tool's files live, and which binary it is.",
     "The one module for where the tool's files live."),
    # ------------------------------------------------------------- stdin
    ("stdin", "The `--problem -` stdin path.",
     "Reading stdin without blocking a terminal."),
    # ------------------------------------------------------------- table
    ("table", "The small pieces every printed table shares.",
     "The table: fixed-width columns for a person."),
    # --------------------------------------------------------- templates
    ("templates", "The two shipped default templates, embedded in the binary.",
     "The two shipped default templates, embedded in the binary."),
    # -------------------------------------------------------------- text
    ("text", "Text safety: the characters this tool neither stores nor prints raw.",
     "The text rules: sanitizing, quoting, joining."),
    # -------------------------------------------------------------- verb
    ("verb", "One row of the verb table.",
     "The verb table's shape."),
    # ----------------------------------------------------------- version
    ("version", "The release version, baked in at build time.",
     "The release version, baked in at build time."),
    # ------------------------------------------------- sqlite_preflight
    ("sqlite_preflight", "The SQLite preflight.",
     "The SQLite preflight: is the library there at all?"),
]


def main() -> int:
    by_file: dict[str, list[tuple[str, str | None]]] = {}
    for module, anchor, new in EDITS:
        by_file.setdefault(module, []).append((anchor, new))

    for module, edits in by_file.items():
        path = SRC / f"{module}.mojo"
        text = path.read_text()
        for anchor, new in edits:
            # Try the docstring first; fall back to a comment run.
            try:
                text = replace_docstring(text, anchor, new if new is not None else "")
                continue
            except ValueError:
                pass
            if new is None:
                raise SystemExit(f"{module}: no rule for {anchor!r}")
            text = replace_comment(text, anchor, new)
        path.write_text(text)
        print(f"{module}.mojo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
