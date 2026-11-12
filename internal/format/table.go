package format

import (
	"os"
	"strings"
	"unicode/utf8"
)

// Pad left-aligns text in width code points.
//
// Width is measured in code points, not bytes: a skill named `café` must not
// shove the column to its right over by one space.
func Pad(text string, width int) string {
	missing := width - utf8.RuneCountInString(text)
	if missing <= 0 {
		return text
	}
	return text + strings.Repeat(" ", missing)
}

// JoinLines joins the lines with newlines and no trailing newline.
//
// main prints the text and adds the one newline the output needs, so a
// newline here would leave a blank line behind.
func JoinLines(lines []string) string {
	return strings.Join(lines, "\n")
}

func homePrefix() string {
	home := os.Getenv("HOME")
	if home == "" {
		return ""
	}
	if strings.HasSuffix(home, "/") {
		return home
	}
	return home + "/"
}

// ShortenHome replaces the reader's home directory with `~`.
//
// A path outside the home is returned unchanged. The home is the one the
// reader's own environment names, so the same row reads the same way for
// every reader on the machine.
func ShortenHome(path string) string {
	home := homePrefix()
	if home == "" {
		return path
	}
	if strings.HasPrefix(path, home) {
		return "~/" + path[len(home):]
	}
	return path
}
