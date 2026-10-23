package platform

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// detectInterval is how often Linux self-detection re-reads /proc and /sys.
const detectInterval = 2 * time.Minute

// WatchSystemState pushes best-effort system state on Linux. On macOS the
// app pushes richer state (SSID, expensive paths, Low Power Mode); on
// Windows nothing is detected and policy defaults to "allow".
func WatchSystemState(ctx context.Context, push func(model.SystemState)) {
	if runtime.GOOS != "linux" {
		return
	}
	var last string
	t := time.NewTicker(detectInterval)
	defer t.Stop()
	for {
		st := detectLinux()
		b, _ := json.Marshal(st)
		if string(b) != last {
			last = string(b)
			push(st)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func detectLinux() model.SystemState {
	var st model.SystemState
	st.Network.Status, st.Network.Interface = "unsatisfied", "none"
	if b, err := os.ReadFile("/proc/net/route"); err == nil {
		for _, line := range strings.Split(string(b), "\n")[1:] {
			f := strings.Fields(line)
			if len(f) > 2 && f[1] == "00000000" { // default route
				st.Network.Status = "satisfied"
				st.Network.Interface = ifaceKind(f[0])
				break
			}
		}
	}
	st.Network.VPN = st.Network.Interface == "other"
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*")
	for _, m := range matches {
		status, _ := os.ReadFile(filepath.Join(m, "status"))
		st.Power.OnBattery = strings.TrimSpace(string(status)) == "Discharging"
		if c, err := os.ReadFile(filepath.Join(m, "capacity")); err == nil {
			if v, err := strconv.Atoi(strings.TrimSpace(string(c))); err == nil {
				st.Power.BatteryPercent = &v
			}
		}
		break
	}
	return st
}

func ifaceKind(name string) string {
	switch {
	case strings.HasPrefix(name, "wl"):
		return "wifi"
	case strings.HasPrefix(name, "en"), strings.HasPrefix(name, "eth"):
		return "ethernet"
	case strings.HasPrefix(name, "ww"), strings.HasPrefix(name, "rmnet"):
		return "cellular"
	}
	return "other"
}
