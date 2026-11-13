// Package format holds the small pieces every verb prints: the sanitizer
// that keeps one problem one line, the JSON writer, the atomic text-file
// replacement and the table helpers.
package format

import "strings"

// isControl reports whether a code point is one the tool replaces: C0
// below 0x20 except tab, plus DEL.
func isControl(code rune) bool {
	if code == 9 {
		return false
	}
	if code < 0x20 {
		return true
	}
	return code == 0x7F
}

// Sanitize turns every control character into a space, so one problem stays
// one line and cannot inject a terminal escape.
func Sanitize(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	for _, c := range text {
		if isControl(c) {
			out.WriteByte(' ')
			continue
		}
		out.WriteRune(c)
	}
	return out.String()
}
