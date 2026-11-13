package cli

import "strings"

func prefixedNotes(lines []string) string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, "skill-log: "+line)
	}
	return strings.Join(out, "\n")
}
