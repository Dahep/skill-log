package cli

import (
	"errors"
	"os"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

type resolveOptions struct {
	id     int64
	fix    string
	dryRun bool
	json   bool
	db     string
}

func resolveVerb() Verb {
	return Verb{
		Name:    "resolve",
		Summary: "stamp one row with the commit that fixes it, by hand",
		Usage: "skill-log resolve --id <n> --fix <commit> [--dry-run]\n" +
			"                      [--json] [--db <path>]",
		Examples: []string{
			"skill-log resolve --id 42 --fix a1b2c3d",
			"skill-log resolve --id 42 --fix a1b2c3d --dry-run",
			"skill-log resolve --id 42 --fix a1b2c3d --json",
		},
		// The flags that consume the next argument. The dispatcher reads this
		// to tell `--fix -h` (a commit spelled `-h`) from a help request.
		ValueFlags: []string{"--id", "--fix", "--db"},
		Notes: "The commit is the squash merge's hash, and the time is now —\n" +
			"run it after the merge, not when the fix is authored. This is\n" +
			"the manual path: the post-merge hook resolves the rows a report\n" +
			"names without anyone remembering.\n" +
			"\n" +
			"Repeating the same call changes nothing; the first stamp's time\n" +
			"stays. A different --fix corrects the resolution with a fresh\n" +
			"timestamp.\n" +
			"\n" +
			"--dry-run previews the stamp and writes nothing. resolve never\n" +
			"creates a store: an unknown id and a missing store are named\n" +
			"failures.",
		Handle: handleResolve,
	}
}

func init() { register(resolveVerb()) }

func parseResolveOptions(args []string) (resolveOptions, error) {
	var options resolveOptions
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--id", "--fix", "--db":
			what := map[string]string{
				"--id": "an id", "--fix": "a commit", "--db": "a path",
			}[arg]
			value, err := takeValue(args, i, arg, what)
			if err != nil {
				return options, err
			}
			switch arg {
			case "--id":
				id, err := parsePositive(value, "--id takes a positive integer")
				if err != nil {
					return options, err
				}
				options.id = id
			case "--fix":
				options.fix = value
			case "--db":
				options.db = value
			}
			i++
		case "--dry-run":
			options.dryRun = true
		case "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + arg}
		}
	}
	if options.id == 0 {
		return options, usageError{"--id needs an id"}
	}
	fix := strings.TrimSpace(options.fix)
	if fix == "" {
		return options, usageError{"--fix needs a commit"}
	}
	// A commit is one line: a value carrying a newline would split the
	// diagnostic that names it, and the store's own line-shaped contract
	// has no room for it.
	if format.Sanitize(fix) != fix {
		return options, usageError{"--fix takes one line: a commit or a ref"}
	}
	options.fix = fix
	return options, nil
}

// renderResolveJSON renders the resolved row as one flat JSON object.
func renderResolveJSON(options resolveOptions, row store.Resolved) string {
	var out []byte
	out = append(out, `{"id":`...)
	out = append(out, formatInt(options.id)...)
	out = append(out, `,"marker":`...)
	out = append(out, format.JSONString(marker.Format(row.Machine, options.id))...)
	out = append(out, `,"skill":`...)
	out = append(out, format.JSONString(row.Skill)...)
	out = append(out, `,"fix":`...)
	out = append(out, format.JSONString(row.Fix)...)
	out = append(out, `,"resolved_at":`...)
	out = append(out, format.JSONString(row.ResolvedAt)...)
	out = append(out, `,"changed":`...)
	out = append(out, format.JSONBool(row.Changed)...)
	out = append(out, `,"dry_run":`...)
	out = append(out, format.JSONBool(options.dryRun)...)
	out = append(out, '}')
	return string(out)
}

func handleResolve(args []string) Outcome {
	options, err := parseResolveOptions(args)
	if err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
	}

	path := settings.ResolveDB(options.db)
	// resolve never makes a store: an absent one is a named failure.
	if info, err := os.Stat(path); err != nil || info.IsDir() {
		return Fail("no store at "+path+" (add a row first)", ExitFailure)
	}

	row, refusal, err := store.ResolveRow(path, options.id, options.fix, options.dryRun)
	if err != nil {
		return Fail("cannot resolve the store: "+path+": "+err.Error(), ExitFailure)
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return Fail(failure.Message, failure.Code)
	}
	if !row.Found {
		return Fail("no invocation "+formatInt(options.id)+" in "+path, ExitFailure)
	}

	if options.json {
		return OK(renderResolveJSON(options, row))
	}

	text := marker.Format(row.Machine, options.id)
	if !row.Changed {
		return OK(text + " already resolved: " + options.fix)
	}
	if options.dryRun {
		return OK(text + " would resolve: " + options.fix)
	}
	return OK(text + " resolved: " + options.fix)
}
