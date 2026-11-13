package format

import (
	"os"
	"strings"
	"unicode/utf8"
)

// Column describes one table column and the cells it renders.
//
// Under returns the sub-lines emitted immediately after the row's line. They
// are not padded as table cells: they belong to the row but have their own
// layout.
type Column[T any] struct {
	Name  string
	Cell  func(T) string
	Under func(T) []string
}

// JoinLines joins the lines with newlines and no trailing newline.
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
func TableLines[T any](columns []Column[T], rows []T) []string {
	widths := make([]int, len(columns))
	for i, column := range columns {
		widths[i] = utf8.RuneCountInString(column.Name)
		for _, row := range rows {
			if width := utf8.RuneCountInString(column.Cell(row)); width > widths[i] {
				widths[i] = width
			}
		}
	}

	lines := make([]string, 0, len(rows)+1)
	lines = append(lines, tableLine(columnNames(columns), widths))
	for _, row := range rows {
		cells := make([]string, 0, len(columns))
		for _, column := range columns {
			cells = append(cells, column.Cell(row))
		}
		lines = append(lines, strings.TrimRight(tableLine(cells, widths), " "))
		for _, column := range columns {
			if column.Under == nil {
				continue
			}
			lines = append(lines, column.Under(row)...)
		}
	}
	return lines
}

func columnNames[T any](columns []Column[T]) []string {
	names := make([]string, 0, len(columns))
	for _, column := range columns {
		names = append(names, column.Name)
	}
	return names
}

func pad(text string, width int) string {
	missing := width - utf8.RuneCountInString(text)
	if missing <= 0 {
		return text
	}
	return text + strings.Repeat(" ", missing)
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
			line.WriteString(pad(name, widths[i]))
		}
	}
	return line.String()
}
