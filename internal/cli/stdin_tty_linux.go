//go:build linux

package cli

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// stdinIsTTY reports whether stdin is a terminal. The question is whether it
// answers the terminal ioctl: a character device such as /dev/null is not one,
// and a redirected pipe or file is not either. Unknown state counts as a
// terminal, so a caller is never left waiting on a read.
func stdinIsTTY() bool {
	if _, err := unix.IoctlGetTermios(int(os.Stdin.Fd()), unix.TCGETS); err != nil {
		return !errors.Is(err, unix.ENOTTY) && !errors.Is(err, unix.EINVAL)
	}
	return true
}
