package cli

import (
	"errors"
	"strconv"
	"strings"
)

// usageError is a usage-shaped failure a parser raises.
type usageError struct {
	message string
}

func (e usageError) Error() string { return "usage: " + e.message }

// usageOutcome turns a parser failure into the CLI's usage outcome.
func usageOutcome(err error) Outcome {
	var usage usageError
	if errors.As(err, &usage) {
		return Fail(usage.Error()[len("usage: "):], ExitUsage)
	}
	return Fail(err.Error(), ExitFailure)
}

// flagDescriptor describes one value-taking flag.
type flagDescriptor struct {
	name string
	what string
	set  func(string) error
}

// flagSet is one verb's flags: the descriptors are the single source for the
// parser, the value-flag list, the parent help scan and the assignment.
type flagSet struct {
	descriptors []flagDescriptor
}

func (s *flagSet) value(name, what string, set func(string) error) {
	s.descriptors = append(s.descriptors, flagDescriptor{name: name, what: what, set: set})
}

// names returns the value-taking flag names in declaration order.
func (s *flagSet) names() []string {
	names := make([]string, 0, len(s.descriptors))
	for _, descriptor := range s.descriptors {
		names = append(names, descriptor.name)
	}
	return names
}

// parse reads value flags from args. Boolean flags are handled by the verb's
// own switch because their presence, rather than their value, is the input.
func (s *flagSet) parse(args []string) error {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		descriptor, ok := s.lookup(arg)
		if !ok {
			continue
		}
		value, err := takeValue(args, i, descriptor.name, descriptor.what)
		if err != nil {
			return err
		}
		if err := descriptor.set(value); err != nil {
			return err
		}
		i++
	}
	return nil
}

func (s *flagSet) lookup(arg string) (flagDescriptor, bool) {
	for _, descriptor := range s.descriptors {
		if descriptor.name == arg {
			return descriptor, true
		}
	}
	return flagDescriptor{}, false
}

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
