package cli

import (
	"errors"
	"strconv"
	"strings"
)

type usageError struct {
	message string
}

func (e usageError) Error() string { return "usage: " + e.message }

func usageOutcome(err error) Outcome {
	var usage usageError
	if errors.As(err, &usage) {
		return Fail(usage.Error()[len("usage: "):], ExitUsage)
	}
	return Fail(err.Error(), ExitFailure)
}

type flagDescriptor struct {
	name string
	what string
	set  func(string) error
	eq   bool
}

type flagSet struct {
	descriptors []flagDescriptor
	switches    map[string]func() error
	positional  bool
}

func (s *flagSet) value(name, what string, set func(string) error) {
	s.descriptors = append(s.descriptors, flagDescriptor{name: name, what: what, set: set})
}

func (s *flagSet) valueEquals(name, what string, set func(string) error) {
	s.descriptors = append(s.descriptors, flagDescriptor{name: name, what: what, set: set, eq: true})
}

func (s *flagSet) switchFlag(name string, set func() error) {
	if s.switches == nil {
		s.switches = make(map[string]func() error)
	}
	s.switches[name] = set
}

func (s *flagSet) names() []string {
	names := make([]string, 0, len(s.descriptors))
	for _, descriptor := range s.descriptors {
		names = append(names, descriptor.name)
	}
	return names
}

func (s *flagSet) parse(args []string) error {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if set, ok := s.switches[arg]; ok {
			if err := set(); err != nil {
				return err
			}
			continue
		}
		descriptor, ok := s.lookup(arg)
		if !ok {
			descriptor, ok = s.lookupPrefix(arg)
			if ok {
				value := strings.TrimPrefix(arg, descriptor.name+"=")
				if err := descriptor.set(value); err != nil {
					return err
				}
				continue
			}
		}
		if !ok {
			if s.positional && !strings.HasPrefix(arg, "-") {
				continue
			}
			return usageError{"unknown option: " + arg}
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

func (s *flagSet) lookupPrefix(arg string) (flagDescriptor, bool) {
	for _, descriptor := range s.descriptors {
		if descriptor.eq && strings.HasPrefix(arg, descriptor.name+"=") {
			return descriptor, true
		}
	}
	return flagDescriptor{}, false
}

func takeValue(args []string, at int, flag, what string) (string, error) {
	next := at + 1
	if next >= len(args) {
		return "", usageError{flag + " needs " + what}
	}
	return args[next], nil
}

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
