package cli

import (
	"strings"

	"github.com/Dahep/skill-log/internal/format"
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
		ValueFlags: resolveFlags(&resolveOptions{}).names(),
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

func resolveFlags(options *resolveOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--id", "an id", func(value string) error {
		id, err := parsePositive(value, "--id takes a positive integer")
		if err != nil {
			return err
		}
		options.id = id
		return nil
	})
	flags.value("--fix", "a commit", func(value string) error { options.fix = value; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	return flags
}

func parseResolveOptions(args []string) (resolveOptions, error) {
	var options resolveOptions
	flags := resolveFlags(&options)
	flags.switchFlag("--dry-run", func() error { options.dryRun = true; return nil })
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
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
	return format.Object(
		format.Int("id", options.id),
		format.Str("marker", rowMarker(row.Machine, options.id)),
		format.Str("skill", row.Skill),
		format.Str("fix", row.Fix),
		format.Str("resolved_at", row.ResolvedAt),
		format.Bool("changed", row.Changed),
		format.Bool("dry_run", options.dryRun),
	)
}

func handleResolve(args []string) Outcome {
	options, err := parseResolveOptions(args)
	if err != nil {
		return usageOutcome(err)
	}

	path := settings.ResolveDB(options.db)
	// resolve never makes a store: an absent one is a named failure.
	opened, _, failure := openStore(path, store.PolicyWrite,
		"no store at "+path+" (add a row first)")
	if failure != nil {
		return Fail(failure.Message, failure.Code)
	}
	if opened != nil {
		opened.Close()
	}

	row, refusal, err := store.ResolveRow(path, options.id, options.fix, options.dryRun)
	if failure := writeOutcome(path, refusal, err); failure != nil {
		return Fail(failure.Message, failure.Code)
	}
	if !row.Found {
		return Fail("no invocation "+formatInt(options.id)+" in "+path, ExitFailure)
	}

	if options.json {
		return OK(renderResolveJSON(options, row))
	}

	text := rowMarker(row.Machine, options.id)
	if !row.Changed {
		return OK(text + " already resolved: " + options.fix)
	}
	if options.dryRun {
		return OK(text + " would resolve: " + options.fix)
	}
	return OK(text + " resolved: " + options.fix)
}
