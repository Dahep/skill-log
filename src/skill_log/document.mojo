"""The document: the fenced usage-log block, parsed and classified.

The fence is the only provenance there is. Everything outside it is
user-owned: the tool never reads, matches, rewrites or deletes a byte
outside the fence — not even with `--force`.
"""

from skill_log.hash import fnv1a64_hex
from skill_log.text import shell_quote

comptime FENCE_OPEN = "<!-- skill-log:usage-log"
comptime FENCE_CLOSE = "<!-- /skill-log:usage-log -->"

comptime STATE_OK = "ok"
comptime STATE_MISSING = "missing"
comptime STATE_STALE = "stale"
comptime STATE_EDITED = "edited"
comptime STATE_VENDORED = "vendored"

comptime FRONTMATTER = "---"
comptime METADATA_KEY = "metadata:"
comptime SOURCE_KEY = "source:"
comptime NAME_KEY = "name:"


struct Block(Movable):
    """One fenced usage-log block, as `parse` found it."""

    var start: Int
    var end: Int
    var content: String
    var template_hash: String
    var content_hash: String

    def __init__(out self):
        self.start = 0
        self.end = 0
        self.content = ""
        self.template_hash = ""
        self.content_hash = ""


struct Parsed(Movable):
    """A document split at its fence: what is before, the block, what is after."""

    var before: String
    var block: Optional[Block]
    var after: String

    def __init__(out self):
        self.before = ""
        self.block = None
        self.after = ""


struct Rendered(Movable):
    """A rendered block: its full fenced text and the two hashes."""

    var text: String
    var template_hash: String
    var content_hash: String

    def __init__(out self):
        self.text = ""
        self.template_hash = ""
        self.content_hash = ""


def render(template: String, name: String, command: String) raises -> Rendered:
    """Render `template` for one skill into a fenced block."""
    var content = substitute(template, name, command)
    var template_hash = fnv1a64_hex(template)
    var content_hash = fnv1a64_hex(content)
    var out = Rendered()
    out.template_hash = template_hash
    out.content_hash = content_hash
    out.text = (
        FENCE_OPEN
        + " template="
        + template_hash
        + " hash="
        + content_hash
        + " -->\n"
        + content
        + "\n"
        + FENCE_CLOSE
        + "\n"
    )
    return out^


def substitute(template: String, name: String, command: String) -> String:
    """`template` with every `<name>` and `<command>` replaced.

    The one exception is a *command line*: there the substituted value is
    shell-quoted, because the reader copies that line out of the block and
    runs it. The prose lines keep the plain substitution.
    """
    var out = String("")
    for line in template.split("\n"):
        var one = String(line)
        out += substitute_line(one, name, command)
        out += "\n"
    return String(out[byte=0 : out.byte_length() - 1])


def substitute_line(line: String, name: String, command: String) -> String:
    """One line of the template, with the placeholders replaced."""
    var quoted = is_command_line(line)
    var out = String("")
    var at = 0
    var n = line.byte_length()
    while at < n:
        var open = line.find("<", at)
        if open < 0:
            out += String(line[byte=at:])
            break
        var close = String(line[byte=open:]).find(">")
        if close < 0:
            out += String(line[byte=at:])
            break
        var tag = String(line[byte=open : open + close + 1])
        var value = String("")
        var known = True
        if tag == "<name>":
            value = name
        elif tag == "<command>":
            value = command
        else:
            known = False
        out += String(line[byte=at:open])
        if not known:
            out += "<"
            at = open + 1
            continue
        if quoted:
            out += shell_quote(value)
        else:
            out += value
        at = open + close + 1
    return out


def is_command_line(line: String) -> Bool:
    """True when the line is a command line of the rendered block."""
    var text = String(line).strip()
    if text == "":
        return False
    if text.startswith("<name>") or text.startswith("<command>"):
        return True
    if not (text.startswith("- ") or text.startswith("* ") or text.startswith("+ ")):
        return False
    var colon = text.find(":")
    if colon < 0:
        return False
    var rest = String(text[byte=colon + 1 :]).strip()
    return rest.startswith("<name>") or rest.startswith("<command>")


def has_placeholder(text: String, placeholder: String) -> Bool:
    """True when `placeholder` occurs in `text`."""
    return text.find(placeholder) != -1


def quoted_placeholder(text: String, placeholder: String) -> Bool:
    """True when `placeholder` sits next to a quote character."""
    var at = text.find(placeholder)
    while at >= 0:
        var before = at - 1
        var after = at + placeholder.byte_length()
        if before >= 0 and is_quote(String(text[byte=before])):
            return True
        if after < text.byte_length() and is_quote(String(text[byte=after])):
            return True
        at = text.find(placeholder, after)
    return False


def is_quote(char: String) -> Bool:
    """True when the character is one of the two shell quote characters."""
    return char == "'" or char == '"'


def validate_template(name: String, template: String) raises:
    """Refuse a template whose placeholders are wrong, by name."""
    if name == "usage-log.md":
        if not has_placeholder(template, "<name>"):
            raise Error(
                "usage-log.md has no <name> placeholder (nothing would"
                " name the skill)"
            )
        if not has_placeholder(template, "<command> add"):
            raise Error(
                "usage-log.md has no <command> add invocation (nothing"
                " would log)"
            )
    elif name == "skill-friction-review.md":
        if not has_placeholder(template, "<command>"):
            raise Error(
                "skill-friction-review.md has no <command> placeholder"
                " (nothing would name the binary)"
            )
    else:
        return

    if quoted_placeholder(template, "<name>"):
        raise Error(
            name
            + " puts <name> next to a quote character (the tool quotes"
            " the value itself, and a quoted placeholder would let the"
            " shell expand it)"
        )
    if quoted_placeholder(template, "<command>"):
        raise Error(
            name
            + " puts <command> next to a quote character (the tool"
            " quotes the value itself, and a quoted placeholder would"
            " let the shell expand it)"
        )


def parse(text: String) -> Parsed:
    """Split `text` at its fence."""
    var parsed = Parsed()
    var open_at = find_line(text, FENCE_OPEN)
    if open_at < 0:
        parsed.before = text
        return parsed^
    var line_end = find_newline(text, open_at)
    if line_end < 0:
        parsed.before = text
        return parsed^
    var header = String(text[byte=open_at:line_end])
    var rest = String(text[byte=line_end + 1 :])
    var close_rel = find_line(rest, FENCE_CLOSE)
    if close_rel < 0:
        parsed.before = text
        return parsed^
    var close_at = line_end + 1 + close_rel
    var close_end = find_newline(text, close_at)
    if close_end < 0:
        close_end = text.byte_length()
    else:
        close_end = close_end + 1
    var block = Block()
    block.start = open_at
    block.end = close_end
    # The content is the bytes between the fence lines, minus one newline:
    # stripping exactly one keeps the round trip honest.
    var content = String(text[byte=line_end + 1 : close_at])
    if content.endswith("\n"):
        var trimmed = String(content[byte=0 : content.byte_length() - 1])
        content = trimmed^
    block.content = content^
    block.template_hash = fence_field(header, "template=")
    block.content_hash = fence_field(header, "hash=")
    parsed.before = String(text[byte=0:open_at])
    parsed.block = block^
    parsed.after = String(text[byte=close_end:])
    return parsed^


def fence_field(header: String, key: String) -> String:
    """The value of `key` in a fence header, or "" when absent."""
    var at = header.find(key)
    if at < 0:
        return ""
    var value_start = at + key.byte_length()
    var rest = String(header[byte=value_start:])
    var cut = rest.find(" ")
    if cut < 0:
        return String(rest.strip())
    return String(rest[byte=0:cut].strip())


def find_line(text: String, prefix: String) -> Int:
    """The byte offset of the first line that starts with `prefix`, or -1."""
    var at = 0
    var n = text.byte_length()
    while at <= n:
        if text.find(prefix, at) == at:
            return at
        var next = find_newline(text, at)
        if next < 0:
            return -1
        at = next + 1
    return -1


def find_newline(text: String, start: Int) -> Int:
    """The offset of the next `\\n` at or after `start`, or -1."""
    return text.find("\n", start)


def append(document: String, block: String) -> String:
    """`document` with the fenced `block` appended at the end."""
    if document == "" or document.endswith("\n"):
        return document + block
    return document + "\n" + block


def rewrite(document: String, block: String) -> String:
    """`document` with its fenced block replaced by `block`."""
    var parsed = parse(document)
    if parsed.block is None:
        return append(document, block)
    return parsed.before + block + parsed.after


def classify(
    document: String,
    current_template_hash: String,
    current_content_hash: String,
    vendored: Bool,
) raises -> String:
    """The document's state, as one of the five names.

    The five states are distinct on purpose: a hand-edited block (`edited`)
    and an older render (`stale`) call for different actions.
    """
    if vendored:
        return STATE_VENDORED
    var parsed = parse(document)
    if parsed.block is None:
        return STATE_MISSING
    var recomputed = fnv1a64_hex(parsed.block.value().content)
    if recomputed != parsed.block.value().content_hash:
        return STATE_EDITED
    if (
        parsed.block.value().template_hash == current_template_hash
        and parsed.block.value().content_hash == current_content_hash
    ):
        return STATE_OK
    return STATE_STALE


def is_vendored(document: String) -> Bool:
    """True when the document carries the vendor stamp.

    The scan is line-based and prefix-based on purpose — no YAML parser is
    needed to recognise the two-line shape: a `source:` key at the start of
    a line inside a frontmatter `metadata:` block is the stamp.
    """
    var n = document.byte_length()
    if not document.startswith(FRONTMATTER):
        return False
    var first_end = find_newline(document, 0)
    if first_end < 0:
        return False
    var in_metadata = False
    var line_start = first_end + 1
    while line_start < n:
        var line_end = find_newline(document, line_start)
        if line_end < 0:
            line_end = n
        var line = String(document[byte=line_start:line_end]).strip()
        if line == FRONTMATTER:
            return False
        if line.startswith(METADATA_KEY):
            in_metadata = True
        elif in_metadata and line.startswith(SOURCE_KEY):
            return True
        line_start = line_end + 1
    return False


def frontmatter_name(document: String) -> String:
    """The skill's name, from its frontmatter `name:` key, or ""."""
    if not document.startswith(FRONTMATTER):
        return ""
    var n = document.byte_length()
    var first_end = find_newline(document, 0)
    if first_end < 0:
        return ""
    var line_start = first_end + 1
    while line_start < n:
        var line_end = find_newline(document, line_start)
        if line_end < 0:
            line_end = n
        var line = String(document[byte=line_start:line_end]).strip()
        if line == FRONTMATTER:
            return ""
        if line.startswith(NAME_KEY):
            var value = String(
                String(line[byte=NAME_KEY.byte_length() :]).strip()
            )
            if value.byte_length() >= 2:
                if value.startswith("\"") and value.endswith("\""):
                    return String(value[byte=1 : value.byte_length() - 1])
                if value.startswith("'") and value.endswith("'"):
                    return String(value[byte=1 : value.byte_length() - 1])
            return value
        line_start = line_end + 1
    return ""
