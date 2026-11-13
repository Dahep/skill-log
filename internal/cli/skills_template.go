package cli

import (
	"os"
	"strings"

	"github.com/Dahep/skill-log/internal/assets"
	"github.com/Dahep/skill-log/internal/document"
	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/settings"
	templatepkg "github.com/Dahep/skill-log/internal/template"
)

// templateJSON is one template object.
func templateJSON(t templatepkg.Template) string {
	// The template file's source is its content, so template_hash and content_hash carry the same value.
	return format.Object(
		format.Str("name", t.Name),
		format.Str("source", t.Source),
		format.Str("content", t.Content),
		format.Str("template_hash", t.Hash),
		format.Str("content_hash", t.Hash),
		format.Bool("moved", t.Moved),
	)
}

// templateAction is one template's outcome under `seed` or `reset`.
type templateAction struct {
	path   string
	action string
	note   string
}

// templateActionJSON is one action object, exactly `path`, `action`.
func templateActionJSON(item templateAction) string {
	return format.Object(
		format.Str("path", item.path),
		format.Str("action", item.action),
	)
}

// handleTemplateShow is `skills template show`: both effective templates, their source and hashes.
func handleTemplateShow(options skillsOptions) Outcome {
	templateDir := templatepkg.ResolveDir(options.templateDir)
	usage, err := templatepkg.Load(assets.UsageLogName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	review, err := templatepkg.Load(assets.ReviewName, templateDir)
	if err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := document.ValidateTemplate(assets.UsageLogName, usage.Content); err != nil {
		return Fail(err.Error(), ExitFailure)
	}
	if err := document.ValidateTemplate(assets.ReviewName, review.Content); err != nil {
		return Fail(err.Error(), ExitFailure)
	}

	if options.json {
		out := `{"templates":[` + templateJSON(usage) + "," + templateJSON(review) + "]}"
		return OK(out)
	}

	var text strings.Builder
	text.WriteString("usage-log.md\n")
	text.WriteString("  source: " + usage.Source + "\n")
	text.WriteString("  template_hash: " + usage.Hash + "\n")
	text.WriteString("  content_hash: " + usage.Hash + "\n")
	text.WriteString("  moved: " + format.JSONBool(usage.Moved) + "\n")
	text.WriteString("\nskill-friction-review.md\n")
	text.WriteString("  source: " + review.Source + "\n")
	text.WriteString("  template_hash: " + review.Hash + "\n")
	text.WriteString("  content_hash: " + review.Hash + "\n")
	text.WriteString("  moved: " + format.JSONBool(review.Moved) + "\n")
	if usage.Moved || review.Moved {
		text.WriteString(
			"\nthe shipped default moved; adopt it with:\n" +
				"  skill-log skills template seed --force\n" +
				"  skill-log skills adopt --dir <dir>\n",
		)
	}
	text.WriteString("\nusage-log snippet (paste into a skill):\n")
	text.WriteString(usage.Content + "\n")
	return OK(text.String())
}

// handleTemplateSeed is `skills template seed`: copy the shipped defaults into the user directory.
//
// It refuses an existing copy without `--force`.
func handleTemplateSeed(options skillsOptions) Outcome {
	dir := settings.TemplatesDir()
	names := assets.Names()
	var actions []templateAction
	refused := false

	for _, name := range names {
		target := joinPath(dir, name)
		if format.IsRegularFile(target) && !options.force {
			refused = true
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionRefused,
				note:   name + ": refused (exists; use --force)",
			})
			continue
		}
		content, err := assets.Shipped(name)
		if err != nil {
			return Fail(err.Error(), ExitFailure)
		}
		if options.dryRun {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionWouldSeed,
				note:   name + ": would write " + target,
			})
			continue
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return Fail("cannot create "+dir+": "+err.Error(), ExitFailure)
		}
		if err := format.WriteText(target, content); err != nil {
			return Fail("cannot write "+target+": "+err.Error(), ExitFailure)
		}
		if err := templatepkg.WriteSeeded(name, document.Hash(content)); err != nil {
			return Fail("cannot write "+templatepkg.SeededPath(name)+": "+err.Error(), ExitFailure)
		}
		actions = append(actions, templateAction{
			path:   target,
			action: templateActionSeeded,
			note:   name + ": wrote " + target,
		})
	}

	text := format.JoinLines(templateActionLines(actions, options.json))

	if refused {
		return failWithText(text, "seed refused an existing copy", ExitFailure)
	}
	return OK(text)
}

// handleTemplateReset is `skills template reset`: delete the user copies back to the shipped defaults.
//
// It refuses while copies exist without `--force`.
func handleTemplateReset(options skillsOptions) Outcome {
	dir := settings.TemplatesDir()
	names := assets.Names()
	var actions []templateAction
	refused := false

	for _, name := range names {
		target := joinPath(dir, name)
		if !format.IsRegularFile(target) {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionAbsent,
				note:   name + ": absent",
			})
			continue
		}
		if !options.force {
			refused = true
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionRefused,
				note:   name + ": refused (exists; use --force)",
			})
			continue
		}
		if options.dryRun {
			actions = append(actions, templateAction{
				path:   target,
				action: templateActionWouldDelete,
				note:   name + ": would delete " + target,
			})
			continue
		}
		if err := os.Remove(target); err != nil {
			return Fail("cannot remove "+target+": "+err.Error(), ExitFailure)
		}
		actions = append(actions, templateAction{
			path:   target,
			action: templateActionDeleted,
			note:   name + ": deleted " + target,
		})
	}

	if options.force && !options.dryRun {
		for _, name := range names {
			templatepkg.ClearSeeded(name)
		}
	}

	text := format.JoinLines(templateActionLines(actions, options.json))

	if refused {
		return failWithText(text, "reset refused while copies exist", ExitFailure)
	}
	return OK(text)
}

// templateActionLines renders the actions as JSON objects or human notes.
func templateActionLines(actions []templateAction, json bool) []string {
	var lines []string
	for _, action := range actions {
		if json {
			lines = append(lines, templateActionJSON(action))
		} else {
			lines = append(lines, action.note)
		}
	}
	return lines
}
