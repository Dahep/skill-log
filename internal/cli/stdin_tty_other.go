//go:build !linux

package cli

import "os"

// stdinIsTTY reports whether stdin is a terminal; unknown state counts as a
// terminal. 1.0 ships for linux, where the ioctl answers exactly; elsewhere a
// character device is the closest approximation available without a dependency.
func stdinIsTTY() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return true
	}
	return info.Mode()&os.ModeCharDevice != 0
}
