package cli

import (
	"strconv"
	"strings"
)

// usageError is a usage-shaped failure a parser raises.
type usageError struct {
	message string
}

func (e usageError) Error() string { return "usage: " + e.message }

// takeValue returns the value of flag, which sits at at+1. A missing value is
// a usage error naming the flag.
func takeValue(args []string, at int, flag, what string) (string, error) {
	next := at + 1
	if next >= len(args) {
		return "", usageError{flag + " needs " + what}
	}
	return args[next], nil
}

// parsePositive reads a positive decimal number, or returns a usage error
// carrying message. Digits only: a sign, a space or a fraction is not an
// invocation id. The cap is checked while the digits are consumed, so an
// oversized number cannot wrap into the valid range.
func parsePositive(value, message string) (int64, error) {
	text := strings.TrimSpace(value)
	if text == "" {
		return 0, usageError{message}
	}
	var number int64
	for _, c := range text {
		if c < '0' || c > '9' {
			return 0, usageError{message}
		}
		number = number*10 + int64(c-'0')
		if number > 2_000_000_000 {
			return 0, usageError{message}
		}
	}
	if number < 1 {
		return 0, usageError{message}
	}
	return number, nil
}

func formatInt(value int64) string { return strconv.FormatInt(value, 10) }
