package cli

import "strings"

// RenderVerb renders one verb's usage block.
func RenderVerb(verb Verb) string {
	var text strings.Builder
	text.WriteString(verb.Name + " — " + verb.Summary + "\n")
	text.WriteString("\nusage:\n  " + verb.Usage + "\n")
	if verb.Notes != "" {
		text.WriteString("\n" + verb.Notes + "\n")
	}
	text.WriteString("\nexamples:\n")
	for _, example := range verb.Examples {
		text.WriteString("  " + example + "\n")
	}
	return text.String()
}

// TopLevelHelp renders the top-level usage.
func TopLevelHelp(verbs []Verb) string {
	var text strings.Builder
	text.WriteString("skill-log — record agent-skill invocations and the friction they produced\n")
	text.WriteString("\nusage:\n")
	text.WriteString("  skill-log <verb> [options]\n")
	text.WriteString("  skill-log            print this usage\n")
	text.WriteString("\nverbs:\n")
	for _, verb := range verbs {
		text.WriteString("  " + verb.Name + "  " + verb.Summary + "\n")
	}
	text.WriteString("\nexamples:\n")
	text.WriteString("  skill-log --version\n")
	text.WriteString("  skill-log --help\n")
	return text.String()
}
