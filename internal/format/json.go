package format

import (
	"fmt"
	"strconv"
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

// escapeString renders one JSON string literal, quotes included.
//
// The writer is hand-rolled rather than encoding/json so it never HTML-escapes
// `<`, `>` or `&` behind the caller's back.
func escapeString(text string) string {
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

// JSONStrings renders an array of strings.
func JSONStrings(items []string) string {
	var out strings.Builder
	out.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(escapeString(item))
	}
	out.WriteByte(']')
	return out.String()
}

// Field is one ordered field of a JSON object.
type Field struct {
	name  string
	value string
}

// Str makes a string field.
func Str(name, value string) Field { return Field{name: name, value: escapeString(value)} }

// Int makes an integer field.
func Int(name string, value int64) Field {
	return Field{name: name, value: strconv.FormatInt(value, 10)}
}

// Bool makes a boolean field.
func Bool(name string, value bool) Field { return Field{name: name, value: JSONBool(value)} }

// Raw makes a field whose value is already rendered JSON.
func Raw(name, value string) Field { return Field{name: name, value: value} }

// Object renders fields as one JSON object, preserving their order.
//
// The field order is part of every JSON contract, so the builder never sorts
// or otherwise rearranges what the caller supplied.
func Object(fields ...Field) string {
	var out strings.Builder
	out.WriteByte('{')
	for i, field := range fields {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(escapeString(field.name))
		out.WriteByte(':')
		out.WriteString(field.value)
	}
	out.WriteByte('}')
	return out.String()
}

// JSONBool renders a JSON boolean.
func JSONBool(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
