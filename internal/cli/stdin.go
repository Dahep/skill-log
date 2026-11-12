package cli

import (
	"bytes"
	"os"
)

// stdinSize is how much of standard input one read takes. A problem's own
// text is one line, so this is generous; anything longer is truncated at the
// first line, which is the invariant that matters.
const stdinSize = 65536

// stdinIsTTY reports whether standard input is a terminal. A hook that reads
// the problem text from stdin must not block on an interactive terminal, so
// the caller asks this first and refuses instead of waiting. False is not the
// safe answer here: a terminal mistaken for a pipe would hang, so an unknown
// answer counts as a terminal.
func stdinIsTTY() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return true
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// readStdinLine reads one line from standard input, without its newline. An
// empty string when standard input carries nothing, or cannot be read.
func readStdinLine() string {
	buffer := make([]byte, stdinSize)
	count := 0
	for count < stdinSize {
		n, err := os.Stdin.Read(buffer[count:])
		if n > 0 {
			count += n
			if bytes.IndexByte(buffer[:count], '\n') != -1 {
				break
			}
		}
		if err != nil {
			break
		}
	}
	if count == 0 {
		return ""
	}
	line := buffer[:count]
	if cut := bytes.IndexByte(line, '\n'); cut != -1 {
		line = line[:cut]
	}
	if len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	return string(line)
}
