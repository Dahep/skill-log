package cli

import (
	"fmt"
	"os"

	"github.com/Dahep/skill-log/internal/format"
)

// Main runs the CLI and returns its exit code.
func Main() (code int) {
	defer func() {
		if recovered := recover(); recovered != nil {
			fmt.Fprintln(os.Stderr, "skill-log: "+format.Sanitize(fmt.Sprint(recovered)))
			code = ExitFailure
		}
	}()
	return Run(os.Args[1:])
}

// Run executes arguments and returns the process exit code.
func Run(args []string) int {
	outcome := run(args)
	if outcome.Failed {
		if outcome.Text != "" {
			fmt.Fprintln(os.Stdout, outcome.Text)
		}
		if outcome.Notes != "" {
			fmt.Fprintln(os.Stderr, outcome.Notes)
		}
		if outcome.Usage != "" {
			fmt.Fprintln(os.Stderr, outcome.Usage)
			return outcome.Failure.Code
		}
		fail(outcome.Failure)
	}
	if outcome.Notes != "" {
		fmt.Fprintln(os.Stderr, outcome.Notes)
	}
	if outcome.Text != "" {
		fmt.Fprintln(os.Stdout, outcome.Text)
	}
	return ExitOK
}

func fail(failure Failure) {
	fmt.Fprintln(os.Stderr, "skill-log: "+format.Sanitize(failure.Message))
	os.Exit(failure.Code)
}

func run(args []string) Outcome {
	if len(args) == 0 {
		return UsageError(TopLevelHelp(buildVerbs()))
	}

	name := args[0]
	if name == "-h" {
		return OK(TopLevelHelp(buildVerbs()))
	}

	verb, ok := findVerb(name)
	if !ok {
		return Fail("unknown verb: "+name, ExitUsage)
	}

	rest := args[1:]
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
