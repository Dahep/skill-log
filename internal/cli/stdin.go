package cli

import (
	"bytes"
	"os"
)

const stdinSize = 65536

// stdinIsTTY reports whether stdin is a terminal; unknown state counts as a terminal.
func stdinIsTTY() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return true
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// readStdinLine reads at most 64 KiB through the first newline from stdin.
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
