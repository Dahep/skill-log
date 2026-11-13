package settings

import (
	"errors"
	"os"
	"time"
)

// ClockOverride is the one clock injection: a test-only stamp that fixes the
// writer's clock.
const ClockOverride = "SKILL_LOG_NOW"

// LocalTimestamp is the writer's local wall clock as ISO 8601 with its offset:
// `2026-11-11T17:04:36-03:00`. SKILL_LOG_NOW, when set, is the stamp.
func LocalTimestamp() string {
	if pinned := os.Getenv(ClockOverride); pinned != "" {
		return pinned
	}
	return time.Now().Format("2006-01-02T15:04:05-07:00")
}

// HostnameUnavailable is the failure for a machine whose hostname cannot be read.
var HostnameUnavailable = errors.New("cannot read this machine's hostname; name it with --machine")

// Hostname is this machine's hostname. A hostname that cannot be read is an error,
// not an empty string: the machine namespaces the store's markers.
func Hostname() (string, error) {
	name, err := os.Hostname()
	if err != nil || name == "" {
		return "", HostnameUnavailable
	}
	return name, nil
}
