package document

import (
	"fmt"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
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
	// StateOK means the fence hash matches the content and the content is the
	// current render.
	StateOK = "ok"
	// StateMissing means no fenced block at all.
	StateMissing = "missing"
	// StateStale means the fence is intact but the content is an older render.
	StateStale = "stale"
	// StateEdited means the content does not match its own fence hash.
	StateEdited = "edited"
	// StateVendored means the skill carries a vendor stamp.
	StateVendored = "vendored"
)

const (
	frontmatter = "---"
	metadataKey = "metadata:"
	sourceKey   = "source:"
	nameKey     = "name:"
)

type Block struct {
	Start        int
	End          int
	Content      string
	TemplateHash string
	ContentHash  string
}

type Parsed struct {
	Before string
	Block  *Block
	After  string
}

type Rendered struct {
	Text         string
	TemplateHash string
	ContentHash  string
}

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

// Substitute returns template with every `<name>` and `<command>` replaced. A
// command line's values are shell-quoted; a prose line's are left plain, because
// the reader copies a command line and runs it, while prose is read.
func Substitute(template, name, command string) string {
	lines := strings.Split(template, "\n")
	for i, line := range lines {
		lines[i] = substituteLine(line, name, command)
	}
	return strings.Join(lines, "\n")
}

func substituteLine(line, name, command string) string {
	quoted := isCommandLine(line)
	var out strings.Builder
	at := 0
	for at < len(line) {
		openRel := strings.IndexByte(line[at:], '<')
		if openRel < 0 {
			out.WriteString(line[at:])
			break
		}
		open := at + openRel
		closeRel := strings.IndexByte(line[open:], '>')
		if closeRel < 0 {
			out.WriteString(line[at:])
			break
		}
		closeAt := open + closeRel
		tag := line[open : closeAt+1]
		var value string
		switch tag {
		case "<name>":
			value = name
		case "<command>":
			value = command
		default:
			// An unknown placeholder is the template's own text.
			out.WriteString(line[at : open+1])
			at = open + 1
			continue
		}
		out.WriteString(line[at:open])
		if quoted {
			out.WriteString(format.ShellQuote(value))
		} else {
			out.WriteString(value)
		}
		at = closeAt + 1
	}
	return out.String()
}

// isCommandLine reports whether the line starts a command: the placeholder is
// the first thing after the indentation, or it follows a markdown list item's
// label and colon.
func isCommandLine(line string) bool {
	text := strings.TrimSpace(line)
	if text == "" {
		return false
	}
	if strings.HasPrefix(text, "<name>") || strings.HasPrefix(text, "<command>") {
		return true
	}
	if !strings.HasPrefix(text, "- ") &&
		!strings.HasPrefix(text, "* ") &&
		!strings.HasPrefix(text, "+ ") {
		return false
	}
	colon := strings.IndexByte(text, ':')
	if colon < 0 {
		return false
	}
	rest := strings.TrimSpace(text[colon+1:])
	return strings.HasPrefix(rest, "<name>") || strings.HasPrefix(rest, "<command>")
}

// quotedPlaceholder reports a placeholder the template itself quoted: the tool
// quotes the value, and nesting the two would put it back in the shell's hands.
func quotedPlaceholder(template, placeholder string) bool {
	for at := 0; ; {
		found := strings.Index(template[at:], placeholder)
		if found < 0 {
			return false
		}
		found += at
		before := found - 1
		after := found + len(placeholder)
		if before >= 0 && isQuote(template[before]) {
			return true
		}
		if after < len(template) && isQuote(template[after]) {
			return true
		}
		at = after
	}
}

func isQuote(char byte) bool { return char == '\'' || char == '"' }

func ValidateTemplate(name, template string) error {
	for _, placeholder := range []string{"<name>", "<command>"} {
		if quotedPlaceholder(template, placeholder) {
			return fmt.Errorf(
				"%s quotes %s; the tool quotes a value itself, and a quoted placeholder would let the shell expand it",
				name, placeholder,
			)
		}
	}
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

// Parse splits text at its fence. Only the first block is recognised.
func Parse(text string) Parsed {
	parsed := Parsed{}
	openAt := findLine(text, FenceOpen)
	if openAt < 0 {
		parsed.Before = text
		return parsed
	}
	lineEnd := findNewline(text, openAt)
	if lineEnd < 0 {
		parsed.Before = text
		return parsed
	}
	header := text[openAt:lineEnd]
	rest := text[lineEnd+1:]
	closeRel := findLine(rest, FenceClose)
	if closeRel < 0 {
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
	// newline Render writes.
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

// fenceField returns the value of key in a fence header, or "" when absent. The
// value runs to the next space: the fence grammar has no quoting.
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

// findLine returns the byte offset of the first line that starts with prefix, or
// -1. A fence in the middle of a line is not a fence.
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

func findNewline(text string, start int) int {
	at := strings.Index(text[start:], "\n")
	if at < 0 {
		return -1
	}
	return start + at
}

// Append returns document with the fenced block appended at the end. A document
// whose last byte is not a newline gets one separator newline.
func Append(document, block string) string {
	if document == "" || strings.HasSuffix(document, "\n") {
		return document + block
	}
	return document + "\n" + block
}

// Rewrite returns document with its fenced block replaced by block. The bytes
// outside the fence are carried through untouched.
func Rewrite(document, block string) string {
	parsed := Parse(document)
	if parsed.Block == nil {
		return Append(document, block)
	}
	return parsed.Before + block + parsed.After
}

// Classify returns the document's state, as one of the five names. The caller
// passes the *current* render's two hashes.
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

// IsVendored reports whether the document carries the vendor stamp: a frontmatter
// `metadata:` block with a `source:` key.
func IsVendored(document string) bool {
	frontmatterLines, ok := frontmatterLines(document)
	if !ok {
		return false
	}
	inMetadata := false
	for _, line := range frontmatterLines {
		if strings.HasPrefix(line, metadataKey) {
			inMetadata = true
		} else if inMetadata && strings.HasPrefix(line, sourceKey) {
			return true
		}
	}
	return false
}

func FrontmatterName(document string) string {
	frontmatterLines, ok := frontmatterLines(document)
	if !ok {
		return ""
	}
	for _, line := range frontmatterLines {
		if !strings.HasPrefix(line, nameKey) {
			continue
		}
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
	return ""
}

// frontmatterLines returns the trimmed lines of the document's frontmatter, and
// whether it opens one: from the opening `---` to the next `---`.
func frontmatterLines(document string) ([]string, bool) {
	if !strings.HasPrefix(document, frontmatter) {
		return nil, false
	}
	firstEnd := findNewline(document, 0)
	if firstEnd < 0 {
		return nil, false
	}
	n := len(document)
	var lines []string
	lineStart := firstEnd + 1
	for lineStart < n {
		lineEnd := findNewline(document, lineStart)
		if lineEnd < 0 {
			lineEnd = n
		}
		line := strings.TrimSpace(document[lineStart:lineEnd])
		if line == frontmatter {
			return lines, true
		}
		lines = append(lines, line)
		lineStart = lineEnd + 1
	}
	return lines, true
}
