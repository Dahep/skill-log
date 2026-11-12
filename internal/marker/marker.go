// Package marker owns the marker grammar: `machine#id`.
//
// A marker is the only way a row is named from outside the store. The
// machine is required because a store's ids are per store: `7` names a
// different row on every machine, `boxA#7` names one row everywhere.
//
// The grammar is strict on purpose. A bare id, a placeholder or a typo is
// never guessed at — it is reported, because the resolution that reads it
// would otherwise stamp the wrong row on some machine. The id is a positive
// decimal: a sign, a space or a fraction is not an invocation id.
package marker

import (
	"strconv"
	"strings"
)

// Marker is one parsed `machine#id` marker.
type Marker struct {
	Machine string
	ID      int64
}

// Text is the canonical spelling: the machine, `#`, the id in decimal.
func (m Marker) Text() string { return Format(m.Machine, m.ID) }

// Format is the canonical spelling of a marker. This is the one place a
// marker is assembled; every site that names a row from outside the store
// calls it, so the grammar is decided once and cannot drift.
func Format(machine string, id int64) string {
	return machine + "#" + strconv.FormatInt(id, 10)
}

// Parse returns the marker value names, or false.
//
// The machine is everything before the first `#` and must be non-empty; the
// id is everything after it and must be a positive decimal. An oversized id
// is refused rather than wrapped, so nothing can parse into a valid-looking
// id that names nothing.
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
