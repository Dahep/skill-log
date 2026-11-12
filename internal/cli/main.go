package cli

import (
	"fmt"
	"os"

	"github.com/Dahep/skill-log/internal/format"
)

// Main runs the CLI and returns its exit code. The catch-all turns anything
// that escapes a handler — a bug, an unexpected condition — into one named
// stderr line, never a Go stack trace.
func Main() (code int) {
	defer func() {
		if recovered := recover(); recovered != nil {
			fmt.Fprintln(os.Stderr, "skill-log: "+format.Sanitize(fmt.Sprint(recovered)))
			code = ExitFailure
		}
	}()
	return Run(os.Args[1:])
}

// Run turns the arguments after the program name into an exit code.
func Run(args []string) int {
	outcome := run(args)
	if outcome.Failed {
		// A validator that was asked for JSON prints its findings on stdout
		// even when it exits 1: the object is the answer, and the exit code
		// says the answer is "not valid".
		if outcome.Text != "" {
			fmt.Fprintln(os.Stdout, outcome.Text)
		}
		if outcome.Notes != "" {
			fmt.Fprintln(os.Stderr, outcome.Notes)
		}
		if outcome.Usage != "" {
			// A usage error prints the usage and the examples on stderr, so
			// stdout stays empty. The block is the whole diagnostic.
			fmt.Fprintln(os.Stderr, outcome.Usage)
			return outcome.Failure.Code
		}
		fail(outcome.Failure)
	}
	if outcome.Notes != "" {
		fmt.Fprintln(os.Stderr, outcome.Notes)
	}
	// An empty text is an empty output, not a blank line: a JSON stream with
	// no rows must stay parseable.
	if outcome.Text != "" {
		fmt.Fprintln(os.Stdout, outcome.Text)
	}
	return ExitOK
}

func fail(failure Failure) {
	// Every line is prefixed so a caller can recognise it, and every control
	// character in the message becomes a space: the contract is one line.
	fmt.Fprintln(os.Stderr, "skill-log: "+format.Sanitize(failure.Message))
	os.Exit(failure.Code)
}

func run(args []string) Outcome {
	if len(args) == 0 {
		// No arguments is a usage error: the usage and the examples, exit 2.
		return UsageError(TopLevelHelp(buildVerbs()))
	}

	name := args[0]
	if name == "-h" {
		// -h is the short form of --help.
		return OK(TopLevelHelp(buildVerbs()))
	}

	verb, ok := findVerb(name)
	if !ok {
		// An unknown verb is one named line. The usage block would be noise
		// on top of it.
		return Fail("unknown verb: "+name, ExitUsage)
	}

	rest := args[1:]
	// `skill-log <verb> --help` prints that verb's own usage and its real
	// invocations, and exits 0. A token that is a value of a value-taking
	// flag is not a help request: `add --problem -h` records the problem
	// `-h`, so the scan steps over every flag's value.
	for i := 0; i < len(rest); i++ {
		if rest[i] == "--help" || rest[i] == "-h" {
			if verb.NestedHelp {
				return verb.Handle(rest)
			}
			return OK(RenderVerb(verb))
		}
		if verb.TakesValue(rest[i]) {
			i++
		}
	}
	return verb.Handle(rest)
}
