package marker

import "strings"

// BadLine is a non-blank line that is not a marker, with its 1-based position.
type BadLine struct {
	Line int
	Text string
}

// ScanLines reads text as one marker per line: the markers it holds, in order,
// and the non-blank lines that are not markers.
func ScanLines(text string) (markers []Marker, bad []BadLine) {
	for i, line := range strings.Split(text, "\n") {
		value := strings.TrimSpace(line)
		if value == "" {
			continue
		}
		parsed, ok := Parse(value)
		if !ok {
			bad = append(bad, BadLine{Line: i + 1, Text: value})
			continue
		}
		markers = append(markers, parsed)
	}
	return markers, bad
}
