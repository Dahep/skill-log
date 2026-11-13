package document

import (
	"fmt"
	"strings"
)

// The fence, spelled once.
const (
	// FenceOpen is the opening fence line's prefix.
	FenceOpen = "<!-- skill-log:usage-log"
	// FenceClose is the closing fence line.
	FenceClose = "<!-- /skill-log:usage-log -->"
)

// The document states, in the order the spec's table lists them.
const (
	// StateOK means the fence hash matches the content and the content is
	// the current render.
	StateOK = "ok"
	// StateMissing means no fenced block at all.
	StateMissing = "missing"
	// StateStale means the fence is intact but the content is an older
	// render.
	StateStale = "stale"
	// StateEdited means the content does not match its own fence hash.
	StateEdited = "edited"
	// StateVendored means the skill carries a vendor stamp.
	StateVendored = "vendored"
)

// The vendor stamp: a skill whose frontmatter carries `metadata:` with a
// `source:` key is a copy of someone else's skill (SPEC §7). Such a skill is
// skipped entirely: its usage-log wording belongs to its upstream, not to
// this tool. The scan is line-based and prefix-based on purpose — no YAML
// parser is needed to recognise the two-line shape, and a key spelled
// `source:` at the start of a line inside a frontmatter `metadata:` block is
// the stamp.
const (
	frontmatter = "---"
	metadataKey = "metadata:"
	sourceKey   = "source:"
	nameKey     = "name:"
)

// Block is one fenced usage-log block, as Parse found it.
//
// Start and End are byte offsets into the document: Start is the first byte
// of the opening fence line, End is one past the last byte of the closing
// fence line. Content is the text strictly between the two fence lines,
// without their trailing newline. TemplateHash and ContentHash are what the
// fence claims.
type Block struct {
	Start        int
	End          int
	Content      string
	TemplateHash string
	ContentHash  string
}

// Parsed is a document split at its fence: what is before, the block, what
// is after.
//
// Block is nil when the document has no fenced block; Before is then the
// whole text and After is empty. The two outside parts are the bytes the
// tool never touches.
type Parsed struct {
	Before string
	Block  *Block
	After  string
}

// Rendered is a rendered block: its full fenced text and the two hashes.
//
// Text is what gets written — the opening fence line carrying both hashes,
// the content, the closing fence line. TemplateHash is the hash of the
// template source; ContentHash is the hash of the content, which is what
// goes into the fence and what Classify recomputes to detect a hand edit.
type Rendered struct {
	Text         string
	TemplateHash string
	ContentHash  string
}

// Render renders template for one skill into a fenced block.
//
// The placeholders are substituted literally: `<name>` becomes the skill's
// name, `<command>` becomes the resolved binary path. The template source is
// hashed as-is (the hash is of the *source*, so a copy in the user directory
// and a shipped default with the same bytes agree), and the content is the
// substituted text without the fence.
//
// ValidateTemplate is the caller's job (it refuses a template whose
// placeholders are wrong by name); rendering a template that has no `<name>`
// at all would silently produce a block no skill can log from.
func Render(template, name, command string) Rendered {
	content := Substitute(template, name, command)
	templateHash := Hash(template)
	contentHash := Hash(content)
	text := FenceOpen +
		" template=" + templateHash +
		" hash=" + contentHash +
		" -->\n" +
		content +
		"\n" +
		FenceClose +
		"\n"
	return Rendered{Text: text, TemplateHash: templateHash, ContentHash: contentHash}
}

// Substitute returns template with every `<name>` and `<command>` replaced.
//
// The replacements are literal — no escaping — because the values are a
// skill name and a path, and the fence never carries them. Each placeholder
// is replaced everywhere it occurs, so a template that names the skill twice
// gets both names.
func Substitute(template, name, command string) string {
	out := strings.ReplaceAll(template, "<name>", name)
	return strings.ReplaceAll(out, "<command>", command)
}

// ValidateTemplate refuses a template whose placeholders are wrong, by name.
//
// `usage-log.md` needs `<name>` and an invocation of `<command> add` — a typo
// there would silently stop every skill from logging, which is exactly the
// failure a refusal must prevent. `skill-friction-review.md` needs
// `<command>`. Any other template name is not validated: the two names above
// are the ones the contract defines placeholders for.
//
// A missing placeholder is an error; the caller turns the message into the
// one named line.
func ValidateTemplate(name, template string) error {
	switch name {
	case "usage-log.md":
		if !strings.Contains(template, "<name>") {
			return fmt.Errorf(
				"usage-log.md has no <name> placeholder (nothing would name the skill)",
			)
		}
		if !strings.Contains(template, "<command> add") {
			return fmt.Errorf(
				"usage-log.md has no <command> add invocation (nothing would log)",
			)
		}
	case "skill-friction-review.md":
		if !strings.Contains(template, "<command>") {
			return fmt.Errorf(
				"skill-friction-review.md has no <command> placeholder (nothing would name the binary)",
			)
		}
	}
	return nil
}

// Parse splits text at its fence.
//
// The scan looks for the opening fence at the start of a line and the closing
// fence at the start of a later line. Only the first block is recognised: a
// second fenced block is not this tool's (the fence grammar names one
// usage-log block per skill), and treating it as after-text keeps the
// never-touch-outside-the-fence rule honest.
//
// Bytes outside the fence are returned untouched — the caller writes Before
// and After back exactly as they came in.
func Parse(text string) Parsed {
	parsed := Parsed{}
	openAt := findLine(text, FenceOpen)
	if openAt < 0 {
		parsed.Before = text
		return parsed
	}
	lineEnd := findNewline(text, openAt)
	if lineEnd < 0 {
		// An opening fence at the very end of the text is not a block.
		parsed.Before = text
		return parsed
	}
	header := text[openAt:lineEnd]
	rest := text[lineEnd+1:]
	closeRel := findLine(rest, FenceClose)
	if closeRel < 0 {
		// An opening fence with no closing fence is not a block at all: it is
		// unfenced text as far as the tool is concerned.
		parsed.Before = text
		return parsed
	}
	closeAt := lineEnd + 1 + closeRel
	closeEnd := findNewline(text, closeAt)
	if closeEnd < 0 {
		closeEnd = len(text)
	} else {
		closeEnd = closeEnd + 1
	}
	block := &Block{Start: openAt, End: closeEnd}
	// The content is the bytes between the two fence lines, minus the one
	// newline Render writes to put the closing fence on its own line.
	// Stripping exactly one keeps the round trip honest: a hand that added a
	// blank line of its own changes the hash, which is the `edited` answer.
	content := text[lineEnd+1 : closeAt]
	if strings.HasSuffix(content, "\n") {
		content = content[:len(content)-1]
	}
	block.Content = content
	block.TemplateHash = fenceField(header, "template=")
	block.ContentHash = fenceField(header, "hash=")
	parsed.Before = text[:openAt]
	parsed.Block = block
	parsed.After = text[closeEnd:]
	return parsed
}

// fenceField returns the value of key in a fence header, or "" when absent.
//
// The value runs to the next space or to the end of the line: the fence
// grammar has no quoting, so a hash never carries either.
func fenceField(header, key string) string {
	at := strings.Index(header, key)
	if at < 0 {
		return ""
	}
	valueStart := at + len(key)
	rest := header[valueStart:]
	cut := strings.Index(rest, " ")
	if cut < 0 {
		return strings.TrimSpace(rest)
	}
	return strings.TrimSpace(rest[:cut])
}

// findLine returns the byte offset of the first line that starts with prefix,
// or -1.
//
// "Starts with" means the line's own first bytes: a fence in the middle of a
// line is not a fence, which keeps prose that mentions the marker from being
// parsed as a block.
func findLine(text, prefix string) int {
	at := 0
	n := len(text)
	for at <= n {
		if strings.HasPrefix(text[at:], prefix) {
			return at
		}
		next := findNewline(text, at)
		if next < 0 {
			return -1
		}
		at = next + 1
	}
	return -1
}

// findNewline returns the offset of the next '\n' at or after start, or -1.
func findNewline(text string, start int) int {
	at := strings.Index(text[start:], "\n")
	if at < 0 {
		return -1
	}
	return start + at
}

// Append returns document with the fenced block appended at the end.
//
// The whole document is user-owned when no block exists yet, so every one of
// its bytes is kept as-is and the block lands after the last of them. The
// block opens on its own line: a document whose last byte is not a newline
// gets one separator newline in front of it. That separator is the one byte
// Append adds outside the fence, and it is required — a fence that opens
// mid-line is not a fence, and the next run would append a second block
// instead of recognising the first.
func Append(document, block string) string {
	if document == "" || strings.HasSuffix(document, "\n") {
		return document + block
	}
	return document + "\n" + block
}

// Rewrite returns document with its fenced block replaced by block.
//
// The splice is before + block + after, the parts Parse split at the fence:
// the bytes outside the fence are carried through untouched — they are never
// read, matched or trimmed, and the caller writes them back exactly as they
// came in.
//
// A document with no fenced block is appended to instead: that is the
// `missing` case, and rewriting nothing would silently drop the block.
func Rewrite(document, block string) string {
	parsed := Parse(document)
	if parsed.Block == nil {
		return Append(document, block)
	}
	return parsed.Before + block + parsed.After
}

// Classify returns the document's state, as one of the five names.
//
// vendored short-circuits: a vendored skill is skipped entirely and its
// block is never looked at. Otherwise:
//
//   - no fenced block → `missing` (unfenced usage-log text is invisible: it
//     is never read or matched, so a skill whose only log section is unfenced
//     text is `missing`)
//   - the fence's `hash` does not match the recomputed content hash → `edited`
//     (a human changed bytes inside the fence)
//   - the fence's `template` hash matches the current template's hash *and*
//     the fence's `hash` matches the current render's content hash → `ok`
//   - anything else → `stale` (the fence is intact — the content matches its
//     own fence hash — but an older render wrote it)
//
// The content hash is what makes `ok` mean "this is the current render": the
// same template rendered for another skill, or with another resolved binary
// path, is a different content and therefore an older render. The caller
// passes the *current* render's two hashes, so Classify itself never renders
// and stays a pure decision over the document.
func Classify(document, currentTemplateHash, currentContentHash string, vendored bool) string {
	if vendored {
		return StateVendored
	}
	parsed := Parse(document)
	if parsed.Block == nil {
		return StateMissing
	}
	recomputed := Hash(parsed.Block.Content)
	if recomputed != parsed.Block.ContentHash {
		return StateEdited
	}
	if parsed.Block.TemplateHash == currentTemplateHash &&
		parsed.Block.ContentHash == currentContentHash {
		return StateOK
	}
	return StateStale
}

// IsVendored reports whether the document carries the vendor stamp.
//
// The stamp is a frontmatter `metadata:` block with a `source:` key (see the
// constant comments above). The scan is line-based: the first line must open
// frontmatter with `---`, and somewhere before the closing `---` there must be
// a `metadata:` line and, after it, a line starting with `source:`. Nothing
// else counts, so a prose mention of `source:` outside the frontmatter is not
// a stamp.
func IsVendored(document string) bool {
	n := len(document)
	// The document must open with the frontmatter fence on its own line.
	if !strings.HasPrefix(document, frontmatter) {
		return false
	}
	firstEnd := findNewline(document, 0)
	if firstEnd < 0 {
		return false
	}
	// Walk the frontmatter lines for `metadata:` and then `source:`.
	inMetadata := false
	lineStart := firstEnd + 1
	for lineStart < n {
		lineEnd := findNewline(document, lineStart)
		if lineEnd < 0 {
			lineEnd = n
		}
		line := strings.TrimSpace(document[lineStart:lineEnd])
		if line == frontmatter {
			return false
		}
		if strings.HasPrefix(line, metadataKey) {
			inMetadata = true
		} else if inMetadata && strings.HasPrefix(line, sourceKey) {
			return true
		}
		lineStart = lineEnd + 1
	}
	return false
}

// FrontmatterName returns the skill's name, from its frontmatter `name:`
// key, or "".
//
// The same line scan as IsVendored: the first `name:` line inside the
// frontmatter wins. Its value is the rest of the line, stripped of whitespace
// and of one matching pair of quotes (a YAML `name: "foo"` is the name
// `foo`). A document with no frontmatter, or no `name:` key in it, answers
// "" — the caller falls back to the skill's directory name, which is what the
// skill is called everywhere else.
func FrontmatterName(document string) string {
	if !strings.HasPrefix(document, frontmatter) {
		return ""
	}
	n := len(document)
	firstEnd := findNewline(document, 0)
	if firstEnd < 0 {
		return ""
	}
	lineStart := firstEnd + 1
	for lineStart < n {
		lineEnd := findNewline(document, lineStart)
		if lineEnd < 0 {
			lineEnd = n
		}
		line := strings.TrimSpace(document[lineStart:lineEnd])
		if line == frontmatter {
			return ""
		}
		if strings.HasPrefix(line, nameKey) {
			value := strings.TrimSpace(line[len(nameKey):])
			if len(value) >= 2 {
				if strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
					return value[1 : len(value)-1]
				}
				if strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'") {
					return value[1 : len(value)-1]
				}
			}
			return value
		}
		lineStart = lineEnd + 1
	}
	return ""
}
