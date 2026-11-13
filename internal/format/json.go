package format

import (
	"fmt"
	"strconv"
	"strings"
)

var escapeRepl = map[rune]string{
	'"':  `\"`,
	'\\': `\\`,
	'\n': `\n`,
	'\r': `\r`,
	'\t': `\t`,
	'\b': `\b`,
	'\f': `\f`,
}

// escapeString renders one JSON string literal, quotes included. The writer is
// hand-rolled rather than encoding/json so it never HTML-escapes `<`, `>` or `&`.
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

type Field struct {
	name  string
	value string
}

func Str(name, value string) Field { return Field{name: name, value: escapeString(value)} }

func Int(name string, value int64) Field {
	return Field{name: name, value: strconv.FormatInt(value, 10)}
}

func Bool(name string, value bool) Field { return Field{name: name, value: JSONBool(value)} }

func Raw(name, value string) Field { return Field{name: name, value: value} }

// Object renders fields as one JSON object, preserving their order: the field
// order is part of every JSON contract.
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

func JSONBool(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
