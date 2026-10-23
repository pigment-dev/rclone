// Package platform holds OS-specific helpers: memory reporting, system
// state self-detection and service (launchd/systemd/Windows) install.
package platform

import (
	"os"
	"os/exec"
	"runtime"
	"runtime/metrics"
	"strconv"
	"strings"
)

// RSS returns the resident set size of this process in bytes (best effort).
func RSS() int64 {
	switch runtime.GOOS {
	case "linux":
		if b, err := os.ReadFile("/proc/self/statm"); err == nil {
			if f := strings.Fields(string(b)); len(f) > 1 {
				if pages, err := strconv.ParseInt(f[1], 10, 64); err == nil {
					return pages * int64(os.Getpagesize())
				}
			}
		}
	case "darwin", "freebsd":
		out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(os.Getpid())).Output()
		if err == nil {
			if kb, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64); err == nil {
				return kb * 1024
			}
		}
	}
	// Fallback: memory mapped by the Go runtime minus what it released.
	s := []metrics.Sample{{Name: "/memory/classes/total:bytes"}, {Name: "/memory/classes/heap/released:bytes"}}
	metrics.Read(s)
	return int64(s[0].Value.Uint64() - s[1].Value.Uint64())
}
