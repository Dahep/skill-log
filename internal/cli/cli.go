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

type Failure struct {
	Message string
	Code    int
}

type Outcome struct {
	Text    string
	Notes   string
	Usage   string
	Failed  bool
	Failure Failure
}

func OK(text string) Outcome { return Outcome{Text: text} }

func OKNotes(text, notes string) Outcome {
	return Outcome{Text: text, Notes: notes}
}

func Fail(message string, code int) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: message, Code: code}}
}

func FailNotes(message string, code int, notes string) Outcome {
	outcome := Fail(message, code)
	outcome.Notes = notes
	return outcome
}

func UsageError(usage string) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: "usage", Code: ExitUsage}, Usage: usage}
}

type Handler func(args []string) Outcome

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
