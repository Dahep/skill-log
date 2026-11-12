// Package cli is the CLI boundary: the verb table, the one help renderer, the
// outcome shape, and the handlers. A handler returns text or a failure; it
// never writes to a stream and never exits.
package cli

// The exit codes, named so a handler cannot invent a fourth one.
const (
	// ExitOK is success or nothing to do.
	ExitOK = 0
	// ExitFailure is an operational failure.
	ExitFailure = 1
	// ExitUsage is a usage error.
	ExitUsage = 2
)

// Failure is a failure the CLI reports as exactly one stderr line.
type Failure struct {
	Message string
	Code    int
}

// Outcome is what a handler returns: text to print, or a failure to report.
//
// Usage carries a usage block printed on stderr so stdout stays empty; the
// block is the whole diagnostic. Notes are additional prefixed stderr lines
// for a verb that has something to say besides the answer.
type Outcome struct {
	Text    string
	Notes   string
	Usage   string
	Failed  bool
	Failure Failure
}

// OK succeeds, with text to print on stdout.
func OK(text string) Outcome { return Outcome{Text: text} }

// OKNotes succeeds, with text on stdout and already-prefixed notes on stderr.
func OKNotes(text, notes string) Outcome {
	return Outcome{Text: text, Notes: notes}
}

// Fail fails with message and exit code.
func Fail(message string, code int) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: message, Code: code}}
}

// FailNotes fails with one summary line plus already-prefixed notes.
func FailNotes(message string, code int, notes string) Outcome {
	outcome := Fail(message, code)
	outcome.Notes = notes
	return outcome
}

// UsageError exits 2 with the usage block on stderr. No extra named line is
// added on top of it.
func UsageError(usage string) Outcome {
	return Outcome{Failed: true, Failure: Failure{Message: "usage", Code: ExitUsage}, Usage: usage}
}

// Handler runs one verb's arguments and returns what to print.
type Handler func(args []string) Outcome

// Verb is one row of the verb table: what the registry stores and what the
// help renderer reads.
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

// TakesValue reports whether arg is one of this verb's value-taking flags.
func (v Verb) TakesValue(arg string) bool {
	for _, flag := range v.ValueFlags {
		if flag == arg {
			return true
		}
	}
	return false
}

// verbOrder is the order the top-level help lists verbs in. A verb that has
// not landed yet is skipped, so the tree's help only promises what works.
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
