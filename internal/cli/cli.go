// Package cli implements the skill-log command-line interface.
package cli

const (
	// ExitOK indicates success.
	ExitOK = 0
	// ExitFailure indicates an operational failure.
	ExitFailure = 1
	// ExitUsage indicates a usage error.
	ExitUsage = 2
)

// Failure describes one CLI failure.
type Failure struct {
	Message string
	Code    int
}

// Outcome contains the result of running a handler.
type Outcome struct {
	Text    string
	Notes   string
	Usage   string
	Failed  bool
	Failure Failure
}

// OK returns a successful outcome.
func OK(text string) Outcome { return Outcome{Text: text} }

// OKNotes returns a successful outcome with stderr notes.
func OKNotes(text, notes string) Outcome {
	return Outcome{Text: text, Notes: notes}
}

// Fail returns a failed outcome.
func Fail(message string, code int) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: message, Code: code}}
}

// FailNotes returns a failed outcome with stderr notes.
func FailNotes(message string, code int, notes string) Outcome {
	outcome := Fail(message, code)
	outcome.Notes = notes
	return outcome
}

// UsageError returns a usage failure.
func UsageError(usage string) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: "usage", Code: ExitUsage}, Usage: usage}
}

// Handler runs one verb and returns its outcome.
type Handler func(args []string) Outcome

// Verb describes one command.
type Verb struct {
	Name       string
	Summary    string
	Usage      string
	Examples   []string
	ValueFlags []string
	Notes      string
	NestedHelp bool
	Handle     Handler
}

// TakesValue reports whether arg is a value-taking flag.
func (v Verb) TakesValue(arg string) bool {
	for _, flag := range v.ValueFlags {
		if flag == arg {
			return true
		}
	}
	return false
}

var verbOrder = []string{
	"add", "show", "stats", "report", "resolve", "resolve-merged",
	"setup", "skills", "--version", "--help",
}

var registry = map[string]Verb{}

func register(verb Verb) { registry[verb.Name] = verb }

func buildVerbs() []Verb {
	verbs := make([]Verb, 0, len(verbOrder))
	for _, name := range verbOrder {
		if verb, ok := registry[name]; ok {
			verbs = append(verbs, verb)
		}
	}
	return verbs
}

func findVerb(name string) (Verb, bool) {
	verb, ok := registry[name]
	return verb, ok
}
