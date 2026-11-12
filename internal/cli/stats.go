package cli

import (
	"errors"
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
		ValueFlags: []string{"--by", "--skill", "--db"},
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

func parseStatsOptions(args []string) (statsOptions, error) {
	options := statsOptions{by: "skill"}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--by":
			value, err := takeValue(args, i, "--by", "a column")
			if err != nil {
				return options, err
			}
			by, err := parseBy(value)
			if err != nil {
				return options, err
			}
			options.by = by
			i++
		case "--by-model":
			// The rotation alias, kept so an existing call keeps working.
			options.by = "model"
		case "--skill":
			value, err := takeValue(args, i, "--skill", "a name")
			if err != nil {
				return options, err
			}
			options.skill = value
			options.givenSkill = true
			i++
		case "--db":
			value, err := takeValue(args, i, "--db", "a path")
			if err != nil {
				return options, err
			}
			options.db = value
			i++
		case "--json":
			options.json = true
		default:
			return options, usageError{"unknown option: " + args[i]}
		}
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

func statsHeaders(column string) []string {
	return []string{column, "invocations", "with_problems", "problems", "resolved", "problems/invocation"}
}

func statsCell(group store.GroupCount, column string, at int) string {
	switch at {
	case 0:
		if column == "worktree" {
			return format.ShortenHome(format.Sanitize(group.Key))
		}
		return format.Sanitize(group.Key)
	case 1:
		return formatInt(group.Invocations)
	case 2:
		return formatInt(group.WithProblems)
	case 3:
		return formatInt(group.Problems)
	case 4:
		return formatInt(group.Resolved)
	default:
		return ratioText(group.Problems, group.Invocations)
	}
}

func renderStatsTable(groups []store.GroupCount, column string) string {
	headers := statsHeaders(column)
	widths := make([]int, len(headers))
	for c, header := range headers {
		widths[c] = len([]rune(header))
		for _, group := range groups {
			if width := len([]rune(statsCell(group, column, c))); width > widths[c] {
				widths[c] = width
			}
		}
	}
	var lines []string
	var header strings.Builder
	for c, name := range headers {
		if c > 0 {
			header.WriteString("  ")
		}
		if c == len(headers)-1 {
			header.WriteString(name)
		} else {
			header.WriteString(format.Pad(name, widths[c]))
		}
	}
	lines = append(lines, header.String())
	for _, group := range groups {
		var line strings.Builder
		for c := range headers {
			if c > 0 {
				line.WriteString("  ")
			}
			if c == len(headers)-1 {
				line.WriteString(statsCell(group, column, c))
			} else {
				line.WriteString(format.Pad(statsCell(group, column, c), widths[c]))
			}
		}
		lines = append(lines, strings.TrimRight(line.String(), " "))
	}
	return format.JoinLines(lines)
}

func renderStatsJSON(groups []store.GroupCount, column string) string {
	lines := make([]string, 0, len(groups))
	for _, group := range groups {
		var out strings.Builder
		out.WriteString("{" + format.JSONString(column) + ":" + format.JSONString(group.Key))
		out.WriteString(`,"invocations":` + formatInt(group.Invocations))
		out.WriteString(`,"with_problems":` + formatInt(group.WithProblems))
		out.WriteString(`,"problems":` + formatInt(group.Problems))
		out.WriteString(`,"resolved":` + formatInt(group.Resolved))
		out.WriteString(`,"problems_per_invocation":` + ratioText(group.Problems, group.Invocations))
		out.WriteString("}")
		lines = append(lines, out.String())
	}
	return format.JoinLines(lines)
}

func handleStats(args []string) Outcome {
	options, err := parseStatsOptions(args)
	if err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			return Fail(usage.Error()[len("usage: "):], ExitUsage)
		}
		return Fail(err.Error(), ExitFailure)
	}
	path := settings.ResolveDB(options.db)

	opened, refusal, err := store.OpenRead(path)
	if err != nil {
		failure := readFailure(path, err)
		return Fail(failure.Message, failure.Code)
	}
	if refusal != nil {
		failure := refusalFailure(refusal)
		return Fail(failure.Message, failure.Code)
	}

	var groups []store.GroupCount
	if opened != nil {
		defer opened.Close()
		ours, err := opened.IsOurs()
		if err != nil {
			failure := readFailure(path, err)
			return Fail(failure.Message, failure.Code)
		}
		if ours {
			groups, err = opened.GroupCounts(options.by, options.skill)
			if err != nil {
				failure := readFailure(path, err)
				return Fail(failure.Message, failure.Code)
			}
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
