package cli

import (
	"fmt"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
	"github.com/Dahep/skill-log/internal/store"
)

type statsOptions struct {
	by         string
	skill      string
	json       bool
	db         string
	givenSkill bool
}

func statsVerb() Verb {
	return Verb{
		Name:    "stats",
		Summary: "count invocations, problems and the friction rate per cut",
		Usage: "skill-log stats [--by <column>] [--skill <name>]\n" +
			"                    [--json] [--db <path>]",
		Examples: []string{
			"skill-log stats",
			"skill-log stats --by model",
			"skill-log stats --by harness --skill skill-log",
			"skill-log stats --by repo --json",
		},
		ValueFlags: statsFlags(&statsOptions{}).names(),
		Notes: "Counts are distinct invocations, runs with at least one problem,\n" +
			"problem rows, and resolved runs; problems/invocation is the rate\n" +
			"between the last two, to two decimals.\n" +
			"\n" +
			"--by picks the cut: skill (the default), harness, model, repo,\n" +
			"worktree, machine or project. An unknown key is refused, not\n" +
			"guessed at. --by-model is kept as an alias for --by model.\n" +
			"\n" +
			"--skill narrows the whole cut to one skill.\n" +
			"\n" +
			"A store that does not exist prints the empty message and exits\n" +
			"0; --json prints nothing, so an empty stream stays parseable.\n" +
			"stats never writes: it creates no store and changes none.",
		Handle: handleStats,
	}
}

func init() { register(statsVerb()) }

func byUsage() string {
	return "--by takes one of " + strings.Join(store.GroupColumns(), ", ")
}

func parseBy(value string) (string, error) {
	key := strings.TrimSpace(value)
	if !store.IsGroupColumn(key) {
		return "", usageError{byUsage()}
	}
	return key, nil
}

func statsFlags(options *statsOptions) *flagSet {
	flags := &flagSet{}
	flags.value("--by", "a column", func(value string) error {
		by, err := parseBy(value)
		if err != nil {
			return err
		}
		options.by = by
		return nil
	})
	flags.value("--skill", "a name", func(value string) error { options.skill = value; options.givenSkill = true; return nil })
	flags.value("--db", "a path", func(value string) error { options.db = value; return nil })
	return flags
}

func parseStatsOptions(args []string) (statsOptions, error) {
	options := statsOptions{by: "skill"}
	flags := statsFlags(&options)
	flags.switchFlag("--by-model", func() error {
		// The rotation alias, kept so an existing call keeps working.
		options.by = "model"
		return nil
	})
	flags.switchFlag("--json", func() error { options.json = true; return nil })
	if err := flags.parse(args); err != nil {
		return options, err
	}
	if options.givenSkill && strings.TrimSpace(options.skill) == "" {
		return options, usageError{"--skill needs a name"}
	}
	options.skill = strings.TrimSpace(options.skill)
	return options, nil
}

// ratioText is problems per invocation, to two decimals, in integer
// arithmetic: hundredths are rounded half up, and the same string feeds the
// table and the JSON so both say the same number.
func ratioText(problems, invocations int64) string {
	if invocations <= 0 {
		return "0.00"
	}
	hundredths := (problems*200 + invocations) / (2 * invocations)
	whole := hundredths / 100
	fraction := hundredths - whole*100
	return fmt.Sprintf("%d.%02d", whole, fraction)
}

func statsEmptyMessage(skill string) string {
	if skill != "" {
		return "no invocations match --skill " + format.Sanitize(skill)
	}
	return "no invocations logged yet"
}

func statsTableColumns(column string) []format.Column[store.GroupCount] {
	return []format.Column[store.GroupCount]{
		{Name: column, Cell: func(group store.GroupCount) string {
			if column == "worktree" {
				return format.ShortenHome(format.Sanitize(group.Key))
			}
			return format.Sanitize(group.Key)
		}},
		{Name: "invocations", Cell: func(group store.GroupCount) string { return formatInt(group.Invocations) }},
		{Name: "with_problems", Cell: func(group store.GroupCount) string { return formatInt(group.WithProblems) }},
		{Name: "problems", Cell: func(group store.GroupCount) string { return formatInt(group.Problems) }},
		{Name: "resolved", Cell: func(group store.GroupCount) string { return formatInt(group.Resolved) }},
		{Name: "problems/invocation", Cell: func(group store.GroupCount) string { return ratioText(group.Problems, group.Invocations) }},
	}
}

func renderStatsTable(groups []store.GroupCount, column string) string {
	return format.JoinLines(format.TableLines(statsTableColumns(column), groups))
}

func renderStatsJSON(groups []store.GroupCount, column string) string {
	lines := make([]string, 0, len(groups))
	for _, group := range groups {
		lines = append(lines, format.Object(
			format.Str(column, group.Key),
			format.Int("invocations", group.Invocations),
			format.Int("with_problems", group.WithProblems),
			format.Int("problems", group.Problems),
			format.Int("resolved", group.Resolved),
			format.Raw("problems_per_invocation", ratioText(group.Problems, group.Invocations)),
		))
	}
	return format.JoinLines(lines)
}

func handleStats(args []string) Outcome {
	options, err := parseStatsOptions(args)
	if err != nil {
		return usageOutcome(err)
	}
	path := settings.ResolveDB(options.db)

	opened, _, failure := openStore(path, store.PolicyRead, "")
	if failure != nil {
		return Fail(failure.Message, failure.Code)
	}

	var groups []store.GroupCount
	if opened != nil {
		defer opened.Close()
		// A store with no tables yet is an empty log: the read answers with
		// no groups rather than an error.
		groups, err = opened.GroupCounts(options.by, options.skill)
		if err != nil {
			failure := readFailure(path, err)
			return Fail(failure.Message, failure.Code)
		}
	}

	if len(groups) == 0 {
		if options.json {
			return OK("")
		}
		return OK(statsEmptyMessage(options.skill))
	}
	if options.json {
		return OK(renderStatsJSON(groups, options.by))
	}
	return OK(renderStatsTable(groups, options.by))
}
