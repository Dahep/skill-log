// Command skill-log records agent-skill invocations and the friction they
// produced.
package main

import (
	"os"

	"github.com/Dahep/skill-log/internal/cli"
)

func main() {
	os.Exit(cli.Main())
}
