package cli

// subcommandHelp is the usage block for one `skills` subcommand: what it does, how
// to call it, and copy-pasteable examples.
func subcommandHelp(sub string) string {
	switch sub {
	case "audit":
		return "skills audit — classify every skill's usage-log block\n" +
			"\nusage:\n" +
			"  skill-log skills audit --dir <dir> [--json] [--dry-run]\n" +
			"\n" +
			"One line per skill, and exit 1 on any state but ok or\n" +
			"vendored. Read-only: it writes nothing, not even a state\n" +
			"directory. An empty directory is refused.\n" +
			"\n" +
			"ok means the block is the current render: the same template,\n" +
			"for that skill's name and the resolved binary path. A moved\n" +
			"binary or a renamed skill makes the block an older render,\n" +
			"and the skill is stale.\n" +
			"\nexamples:\n" +
			"  skill-log skills audit --dir .agents/skills\n" +
			"  skill-log skills audit --dir .agents/skills --json\n" +
			"  skill-log skills audit --dir .agents/skills --dry-run\n"
	case "adopt":
		return "skills adopt — make a repo's skills conform\n" +
			"\nusage:\n" +
			"  skill-log skills adopt --dir <dir> [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Appends a fenced block where there is none, rewrites a block\n" +
			"whose content is an older render, and rewrites a hand-edited\n" +
			"block only with --force. A vendored skill is skipped entirely.\n" +
			"Not one byte outside the fence is rewritten or removed —\n" +
			"unfenced text is never touched, not even with --force. A\n" +
			"second run changes nothing.\n" +
			"\n" +
			"One line per skill: the action (appended, rewritten,\n" +
			"unchanged, refused, skipped), the state it was in, the skill\n" +
			"and its path. --json emits the same as one object per skill.\n" +
			"--dry-run prints the same answer and writes nothing.\n" +
			"\n" +
			"Exits 0 when the directory ends conformant, 1 when any skill\n" +
			"is refused — an edited block left untouched without --force.\n" +
			"A directory that holds no skills is refused.\n" +
			"\nexamples:\n" +
			"  skill-log skills adopt --dir .agents/skills\n" +
			"  skill-log skills adopt --dir .agents/skills --force\n" +
			"  skill-log skills adopt --dir .agents/skills --dry-run --json\n"
	case "template show":
		return "skills template show — the effective templates and their provenance\n" +
			"\nusage:\n" +
			"  skill-log skills template show [--json] [--template-dir <dir>]\n" +
			"\n" +
			"Prints both effective templates, their source, their hashes,\n" +
			"and whether the shipped default has moved since the user copy\n" +
			"was seeded. The usage-log template is also the pasteable\n" +
			"snippet. A moved default is reported with the two commands\n" +
			"that adopt it and never applied.\n" +
			"\nexamples:\n" +
			"  skill-log skills template show\n" +
			"  skill-log skills template show --json\n" +
			"  skill-log skills template show --template-dir ./my-templates\n"
	case "template seed":
		return "skills template seed — copy the shipped defaults into the user directory\n" +
			"\nusage:\n" +
			"  skill-log skills template seed [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Copies the two shipped defaults into\n" +
			"${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/. Without\n" +
			"--force it refuses to overwrite an existing copy.\n" +
			"\n" +
			"--json emits one object per template: the path and the\n" +
			"action, which is one of seeded, would_seed (a dry run) or\n" +
			"refused (a copy is already there).\n" +
			"\nexamples:\n" +
			"  skill-log skills template seed\n" +
			"  skill-log skills template seed --force\n" +
			"  skill-log skills template seed --force --dry-run\n"
	case "template reset":
		return "skills template reset — delete the user copies, back to the shipped defaults\n" +
			"\nusage:\n" +
			"  skill-log skills template reset [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Deletes the user copies and returns to the shipped defaults,\n" +
			"which the next adopt re-renders. It refuses while copies\n" +
			"exist unless --force is given.\n" +
			"\n" +
			"--json emits one object per template: the path and the\n" +
			"action, which is one of deleted, would_delete (a dry run),\n" +
			"absent (there was no copy) or refused (copies are there).\n" +
			"\nexamples:\n" +
			"  skill-log skills template reset --force\n" +
			"  skill-log skills template reset --force --dry-run\n" +
			"  skill-log skills template reset\n"
	case "template":
		return "skills template — the two shipped usage-log templates\n" +
			"\nusage:\n" +
			"  skill-log skills template show [--json] [--template-dir <dir>]\n" +
			"  skill-log skills template seed [--force] [--dry-run] [--json]\n" +
			"  skill-log skills template reset [--force] [--dry-run] [--json]\n" +
			"\n" +
			"Subcommands, not mode flags: show reports, seed copies the\n" +
			"shipped defaults into the user directory, reset deletes them\n" +
			"back to the shipped defaults. The templates resolve by\n" +
			"--template-dir, then SKILL_LOG_TEMPLATE_DIR, then\n" +
			"${XDG_CONFIG_HOME:-~/.config}/skill-log/templates/, then the\n" +
			"shipped default in the binary.\n" +
			"\n" +
			"seed and reset emit one JSON object per template -- the path\n" +
			"and the action -- so a caller reads a value and never\n" +
			"matches prose.\n" +
			"\nexamples:\n" +
			"  skill-log skills template show\n" +
			"  skill-log skills template seed --force\n" +
			"  skill-log skills template reset --force\n"
	}
	return ""
}
