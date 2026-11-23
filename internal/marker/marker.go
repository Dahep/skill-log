// Package marker owns the marker grammar: `machine#row`. A row is a bare id for
// an invocation, `e<id>` for an error row, or `s<id>` for a signature.
package marker

import (
	"strconv"
	"strings"
)

// Kind is what a marker names. The zero value is an invocation row, which is
// the bare form every marker written before error and signature rows existed —
// so an old marker keeps its meaning without a version.
type Kind int

const (
	Invocation Kind = iota
	Error
	Signature
)

// Label is the row kind as a diagnostic names it.
func (k Kind) Label() string {
	switch k {
	case Error:
		return "error"
	case Signature:
		return "signature"
	default:
		return "invocation"
	}
}

type Marker struct {
	Machine string
	Kind    Kind
	ID      int64
}

func (m Marker) Text() string { return Format(m.Machine, m.Kind, m.ID) }

// Format renders a marker. This is the only place the grammar is written: a
// marker is never assembled by hand.
func Format(machine string, kind Kind, id int64) string {
	prefix := ""
	switch kind {
	case Error:
		prefix = "e"
	case Signature:
		prefix = "s"
	}
	return machine + "#" + prefix + strconv.FormatInt(id, 10)
}

// Parse returns the marker value it names, or false. The id is a positive
// decimal after an optional row-kind prefix, and an unknown prefix is refused
// rather than guessed at: `machine#x5` is not a marker and never becomes one.
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
	kind, digits, ok := splitKind(text[cut+1:])
	if !ok {
		return Marker{}, false
	}
	id, ok := parseID(digits)
	if !ok {
		return Marker{}, false
	}
	return Marker{Machine: machine, Kind: kind, ID: id}, true
}

// ParseRef reads a row reference that carries no machine, the form a local verb
// takes: `42` for an invocation, `e42` for an error, `s42` for a signature.
func ParseRef(value string) (Kind, int64, bool) {
	kind, digits, ok := splitKind(strings.TrimSpace(value))
	if !ok {
		return Invocation, 0, false
	}
	id, ok := parseID(digits)
	if !ok {
		return Invocation, 0, false
	}
	return kind, id, true
}

// splitKind separates an optional row-kind prefix from the digits that follow.
// An empty remainder, or a character that is neither a known prefix nor a digit,
// is refused.
func splitKind(text string) (Kind, string, bool) {
	text = strings.TrimSpace(text)
	switch {
	case strings.HasPrefix(text, "e"):
		return Error, text[1:], text[1:] != ""
	case strings.HasPrefix(text, "s"):
		return Signature, text[1:], text[1:] != ""
	}
	return Invocation, text, text != ""
}

// parseID reads a positive decimal. An id of 0 and an oversized id are refused
// rather than wrapped.
func parseID(digits string) (int64, bool) {
	var number int64
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
		number = number*10 + int64(c-'0')
		if number > 2_000_000_000 {
			return 0, false
		}
	}
	if number < 1 {
		return 0, false
	}
	return number, true
}
