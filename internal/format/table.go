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

// TableLines renders one table's header and rows.
//
// Columns are padded to their widest value, separated by two spaces, and
// trailing spaces are removed from every row. The last column is not padded,
// so the right edge stays exactly where its content ends.
func TableLines(headers []string, rows [][]string) []string {
	widths := make([]int, len(headers))
	for i, header := range headers {
		widths[i] = utf8.RuneCountInString(header)
		for _, row := range rows {
			if i >= len(row) {
				continue
			}
			if width := utf8.RuneCountInString(row[i]); width > widths[i] {
				widths[i] = width
			}
		}
	}

	lines := make([]string, 0, len(rows)+1)
	lines = append(lines, tableLine(headers, widths))
	for _, row := range rows {
		lines = append(lines, strings.TrimRight(tableLine(row, widths), " "))
	}
	return lines
}

func tableLine(cells []string, widths []int) string {
	var line strings.Builder
	for i, name := range cells {
		if i > 0 {
			line.WriteString("  ")
		}
		if i == len(cells)-1 {
			line.WriteString(name)
		} else {
			line.WriteString(Pad(name, widths[i]))
		}
	}
	return line.String()
}
