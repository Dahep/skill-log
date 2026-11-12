package format

import (
	"fmt"
	"strings"
)

// escapeRepl is the JSON escape each reserved character becomes.
var escapeRepl = map[rune]string{
	'"':  `\"`,
	'\\': `\\`,
	'\n': `\n`,
	'\r': `\r`,
	'\t': `\t`,
	'\b': `\b`,
	'\f': `\f`,
}

// EscapeString renders one JSON string literal, quotes included.
//
// Every character the JSON grammar reserves is escaped; everything else is
// copied through, so a problem's own words survive intact. The writer is
// hand-rolled rather than encoding/json so it never HTML-escapes `<`, `>`
// or `&` behind the caller's back: the text the user wrote is the text
// that comes back out.
func EscapeString(text string) string {
	var out strings.Builder
	out.Grow(len(text) + 2)
	out.WriteByte('"')
	for _, c := range text {
		if repl, ok := escapeRepl[c]; ok {
			out.WriteString(repl)
			continue
		}
		if c < 0x20 {
			fmt.Fprintf(&out, `\u%04x`, c)
			continue
		}
		out.WriteRune(c)
	}
	out.WriteByte('"')
	return out.String()
}

// JSONString is a JSON string value, quotes included.
func JSONString(text string) string { return EscapeString(text) }

// JSONStrings renders an array of strings.
func JSONStrings(items []string) string {
	var out strings.Builder
	out.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(EscapeString(item))
	}
	out.WriteByte(']')
	return out.String()
}

// JSONBool renders a JSON boolean.
func JSONBool(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
