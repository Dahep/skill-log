// Package format holds the small pieces every verb prints: the sanitizer
// that keeps one problem one line, the JSON writer, the atomic text-file
// replacement and the table helpers.
package format

import "strings"

// IsControl reports whether a code point is one the tool replaces: C0
// below 0x20 except tab, plus DEL.
func IsControl(code rune) bool {
	if code == 9 {
		return false
	}
	if code < 0x20 {
		return true
	}
	return code == 0x7F
}

// Sanitize turns every control character into a space. A newline becomes
// a space, so one problem stays one line and cannot inject a terminal
// escape, and a diagnostic carrying a path with a newline in it stays a
// diagnostic on one line.
func Sanitize(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	for _, c := range text {
		if IsControl(c) {
			out.WriteByte(' ')
			continue
		}
		out.WriteRune(c)
	}
	return out.String()
}

// Prefixed renders lines as the stderr notes main prints: every one
// carries the same `skill-log: ` prefix as a failure. An empty list
// produces no notes at all.
func Prefixed(lines []string) string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, "skill-log: "+line)
	}
	return strings.Join(out, "\n")
}
