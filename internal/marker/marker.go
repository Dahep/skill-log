// Package marker owns the marker grammar: `machine#id`.
package marker

import (
	"strconv"
	"strings"
)

type Marker struct {
	Machine string
	ID      int64
}

func (m Marker) Text() string { return Format(m.Machine, m.ID) }

func Format(machine string, id int64) string {
	return machine + "#" + strconv.FormatInt(id, 10)
}

// Parse returns the marker value names, or false. The id is a positive decimal:
// an oversized id is refused rather than wrapped.
func Parse(value string) (Marker, bool) {
	text := strings.TrimSpace(value)
	cut := strings.Index(text, "#")
	if cut <= 0 || cut == len(text)-1 {
		return Marker{}, false
	}
	machine := strings.TrimSpace(text[:cut])
	if machine == "" {
		return Marker{}, false
	}
	digits := text[cut+1:]
	var number int64
	for _, c := range digits {
		if c < '0' || c > '9' {
			return Marker{}, false
		}
		number = number*10 + int64(c-'0')
		if number > 2_000_000_000 {
			return Marker{}, false
		}
	}
	if number < 1 {
		return Marker{}, false
	}
	return Marker{Machine: machine, ID: number}, true
}
