"""The document: the fenced usage-log block, parsed and classified.

The block the tool adopts into a skill is delimited and self-describing:

    <!-- skill-log:usage-log template=<hash> hash=<hash> -->
    ## Usage log
    ...
    <!-- /skill-log:usage-log -->

`template` is the hash of the template source that rendered the block;
`hash` is the hash of the block's content. The fence is the only
provenance there is. Everything outside it is user-owned: the tool never
reads, matches, rewrites or deletes a byte outside the fence — not even
with `--force`. A skill that has usage-log text but no fence is
`missing`; reconciling the old section is a human task.

This module answers the four questions the fence makes distinguishable,
and keeps them distinct (ADR-0003):

1. **Is there a block at all?** `parse` splits the text into
   `before · block · after`. No fence means no block.
2. **Was the block edited by hand?** The fence's `hash` is the hash the
   block's content had when the tool wrote it. Recompute it: a mismatch
   means a human edited inside the fence (`edited`).
3. **Did the template move since the block was written?** The fence's
   `template` hash is the hash of the template source that rendered it.
   The current template's own hash is compared (`stale` vs `ok`).
4. **Is the skill vendored?** A vendor stamp means skip entirely
   (`vendored`).

The shipped-default-moved question is *not* one of these: it lives in
the state directory's seeded-from record, outside this module.

`rewrite` and `append` (ticket #18) are the write half: both splice
through `parse`'s `before · block · after` split, so no byte outside the
fence is touched — `rewrite` replaces the block in place, `append` adds
one at the end of a document that has none. Everything else here is
unchanged.
"""

from skill_log.hash import fnv1a64_hex

# The fence, spelled once.
comptime FENCE_OPEN = "<!-- skill-log:usage-log"
comptime FENCE_CLOSE = "<!-- /skill-log:usage-log -->"

# The document states, in the order the spec's table lists them.
comptime STATE_OK = "ok"
comptime STATE_MISSING = "missing"
comptime STATE_STALE = "stale"
comptime STATE_EDITED = "edited"
comptime STATE_VENDORED = "vendored"

# The vendor stamp: a skill whose frontmatter carries `metadata:` with a
# `source:` key is a copy of someone else's skill (this machine's
# vendored-skill convention — the dotfiles repo's vendored `tuicr` skill
# is the model). Such a skill is skipped entirely: its usage-log wording
# belongs to its upstream, not to this tool. The scan is line-based and
# prefix-based on purpose — no YAML parser is needed to recognise the
# two-line shape, and a key spelled `source:` at the start of a line
# inside a frontmatter `metadata:` block is the stamp. This is a
# ticket-level decision (the brief), documented here and in
# `skills audit --help`.
comptime FRONTMATTER = "---"
comptime METADATA_KEY = "metadata:"
comptime SOURCE_KEY = "source:"
comptime NAME_KEY = "name:"


struct Block(Movable):
    """One fenced usage-log block, as `parse` found it.

    `start` and `end` are byte offsets into the document: `start` is the
    first byte of the opening fence line, `end` is one past the last byte
    of the closing fence line. `content` is the text strictly between the
    two fence lines, without their trailing newline. `template_hash` and
    `content_hash` are what the fence claims.
    """

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
    """A document split at its fence: what is before, the block, what is
    after.

    `block` is `None` when the document has no fenced block; `before` is
    then the whole text and `after` is empty. The two outside parts are
    the bytes the tool never touches.
    """

    var before: String
    var block: Optional[Block]
    var after: String

    def __init__(out self):
        self.before = ""
        self.block = None
        self.after = ""


struct Rendered(Movable):
    """A rendered block: its full fenced text and the two hashes.

    `text` is what gets written — the opening fence line carrying both
    hashes, the content, the closing fence line. `template_hash` is the
    hash of the template source; `content_hash` is the hash of the
    content, which is what goes into the fence and what `classify`
    recomputes to detect a hand edit.
    """

    var text: String
    var template_hash: String
    var content_hash: String

    def __init__(out self):
        self.text = ""
        self.template_hash = ""
        self.content_hash = ""


def render(template: String, name: String, command: String) raises -> Rendered:
    """Render `template` for one skill into a fenced block.

    The placeholders are substituted literally: `<name>` becomes the
    skill's name, `<command>` becomes the resolved binary path. The
    template source is hashed as-is (the hash is of the *source*, so a
    copy in the user directory and a shipped default with the same bytes
    agree), and the content is the substituted text without the fence.

    `validate_template` is the caller's job (it refuses a template whose
    placeholders are wrong by name); rendering a template that has no
    `<name>` at all would silently produce a block no skill can log
    from.
    """
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

    The replacements are literal — no escaping — because the values are
    a skill name and a path, and the fence never carries them. Each
    placeholder is replaced everywhere it occurs, so a template that
    names the skill twice gets both names.
    """
    var out = String(template).replace("<name>", name)
    out = out.replace("<command>", command)
    return out


def has_placeholder(text: String, placeholder: String) -> Bool:
    """True when `placeholder` occurs in `text`."""
    return text.find(placeholder) != -1


def validate_template(name: String, template: String) raises:
    """Refuse a template whose placeholders are wrong, by name.

    `usage-log.md` needs `<name>` and an invocation of `<command> add` —
    a typo there would silently stop every skill from logging, which is
    exactly the failure a refusal must prevent. `skill-friction-review.md`
    needs `<command>`. Any other template name is not validated: the two
    names above are the ones the contract defines placeholders for.

    A missing placeholder raises; the caller turns the message into the
    one named line.
    """
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


def parse(text: String) -> Parsed:
    """Split `text` at its fence.

    The scan looks for the opening fence at the start of a line and the
    closing fence at the start of a later line. Only the first block is
    recognised: a second fenced block is not this tool's (the fence
    grammar names one usage-log block per skill), and treating it as
    after-text keeps the never-touch-outside-the-fence rule honest.

    Bytes outside the fence are returned untouched — the caller writes
    `before` and `after` back exactly as they came in.
    """
    var parsed = Parsed()
    var open_at = find_line(text, FENCE_OPEN)
    if open_at < 0:
        parsed.before = text
        return parsed^
    var line_end = find_newline(text, open_at)
    if line_end < 0:
        # An opening fence at the very end of the text is not a block.
        parsed.before = text
        return parsed^
    var header = String(text[byte=open_at:line_end])
    var rest = String(text[byte=line_end + 1 :])
    var close_rel = find_line(rest, FENCE_CLOSE)
    if close_rel < 0:
        # An opening fence with no closing fence is not a block at all:
        # it is unfenced text as far as the tool is concerned.
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
    # The content is the bytes between the two fence lines, minus the
    # one newline `render` writes to put the closing fence on its own
    # line. Stripping exactly one keeps the round trip honest: a hand
    # that added a blank line of its own changes the hash, which is the
    # `edited` answer.
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
    """The value of `key` in a fence header, or "" when absent.

    The value runs to the next space or to the end of the line: the
    fence grammar has no quoting, so a hash never carries either.
    """
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
    """The byte offset of the first line that starts with `prefix`, or
    -1.

    "Starts with" means the line's own first bytes: a fence in the
    middle of a line is not a fence, which keeps prose that mentions the
    marker from being parsed as a block.
    """
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
    """`document` with the fenced `block` appended at the end.

    The whole document is user-owned when no block exists yet, so every
    one of its bytes is kept as-is and the block lands after the last of
    them. The block opens on its own line: a document whose last byte is
    not a newline gets one separator newline in front of it. That
    separator is the one byte `append` adds outside the fence, and it is
    required — a fence that opens mid-line is not a fence, and the next
    run would append a second block instead of recognising the first.
    """
    if document == "" or document.endswith("\n"):
        return document + block
    return document + "\n" + block


def rewrite(document: String, block: String) -> String:
    """`document` with its fenced block replaced by `block`.

    The splice is `before + block + after`, the parts `parse` split at
    the fence: the bytes outside the fence are carried through
    untouched — they are never read, matched or trimmed, and the caller
    writes them back exactly as they came in.

    A document with no fenced block is appended to instead: that is the
    `missing` case, and rewriting nothing would silently drop the block.
    """
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

    `vendored` short-circuits: a vendored skill is skipped entirely and
    its block is never looked at. Otherwise:

    - no fenced block → `missing` (unfenced usage-log text is invisible:
      it is never read or matched, so a skill whose only log section is
      unfenced text is `missing`)
    - the fence's `hash` does not match the recomputed content hash →
      `edited` (a human changed bytes inside the fence)
    - the fence's `template` hash matches the current template's hash
      *and* the fence's `hash` matches the current render's content
      hash → `ok`
    - anything else → `stale` (the fence is intact — the content matches
      its own fence hash — but an older render wrote it)

    The content hash is what makes `ok` mean "this is the current
    render": the same template rendered for another skill, or with
    another resolved binary path, is a different content and therefore
    an older render. The caller passes the *current* render's two
    hashes, so `classify` itself never renders and stays a pure
    decision over the document.
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

    The stamp is a frontmatter `metadata:` block with a `source:` key
    (see the constant comments above). The scan is line-based: the first
    line must open frontmatter with `---`, and somewhere before the
    closing `---` there must be a `metadata:` line and, after it, a line
    starting with `source:`. Nothing else counts, so a prose mention of
    `source:` outside the frontmatter is not a stamp.
    """
    var n = document.byte_length()
    # The document must open with the frontmatter fence on its own line.
    if not document.startswith(FRONTMATTER):
        return False
    var first_end = find_newline(document, 0)
    if first_end < 0:
        return False
    # Walk the frontmatter lines for `metadata:` and then `source:`.
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
    """The skill's name, from its frontmatter `name:` key, or "".

    The same line scan as `is_vendored`: the first `name:` line inside
    the frontmatter wins. Its value is the rest of the line, stripped of
    whitespace and of one matching pair of quotes (a YAML `name: "foo"`
    is the name `foo`). A document with no frontmatter, or no `name:`
    key in it, answers "" — the caller falls back to the skill's
    directory name, which is what the skill is called everywhere else.
    """
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
