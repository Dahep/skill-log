package cli

// version is the release version, baked in at build time from the tag with
// -ldflags '-X github.com/Dahep/skill-log/internal/cli.version=...'.
var version = "0.0.0-dev"

// Version is the release version of this build.
func Version() string { return version }

func versionVerb() Verb {
	return Verb{
		Name:     "--version",
		Summary:  "print the release version",
		Usage:    "skill-log --version",
		Examples: []string{"skill-log --version", "skill-log --help"},
		Handle: func(args []string) Outcome {
			_ = args
			return OK(Version())
		},
	}
}

func helpVerb() Verb {
	return Verb{
		Name:     "--help",
		Summary:  "print this usage and the available verbs",
		Usage:    "skill-log --help",
		Examples: []string{"skill-log --help", "skill-log -h", "skill-log --version"},
		Handle: func(args []string) Outcome {
			_ = args
			return OK(TopLevelHelp(buildVerbs()))
		},
	}
}

func init() {
	register(versionVerb())
	register(helpVerb())
}
