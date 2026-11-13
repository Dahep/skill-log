// Command skill-log records agent-skill invocations and their friction.
package main

import (
	"os"

	"github.com/Dahep/skill-log/internal/cli"
)

func main() {
	os.Exit(cli.Main())
}
