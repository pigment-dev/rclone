// Package policy decides whether a job may run under the current network
// and power conditions, and which bandwidth limit applies.
package policy

import (
	"fmt"
	"slices"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// Evaluate returns ("", true) when job may run, or a human reason why it
// must wait. st is nil when no system state is known (allow).
func Evaluate(j model.Job, s model.Settings, st *model.SystemState) (string, bool) {
	if st == nil {
		return "", true
	}
	n, p := st.Network, st.Power
	if st.Sleeping {
		return "Waiting for wake: system is asleep", false
	}
	if n.Status == "unsatisfied" || n.Interface == "none" {
		return "Waiting for network: offline", false
	}
	if n.Interface == "cellular" && (!j.Network.AllowCellular || !s.Network.AllowCellular) {
		return "Waiting for Wi-Fi: on cellular", false
	}
	if n.Expensive && (!j.Network.AllowExpensive || !s.Network.AllowExpensive) {
		return "Waiting for an unmetered network: connection is metered", false
	}
	if j.Network.WifiOnly && n.Interface != "wifi" {
		return fmt.Sprintf("Waiting for Wi-Fi: on %s", ifaceName(n.Interface)), false
	}
	ssid := ""
	if n.SSID != nil {
		ssid = *n.SSID
	}
	if len(j.Network.SSIDAllow) > 0 {
		if n.Interface != "wifi" {
			return fmt.Sprintf("Waiting for an allowed Wi-Fi: on %s", ifaceName(n.Interface)), false
		}
		if ssid == "" {
			return "Waiting for an allowed Wi-Fi: network name unknown", false
		}
		if !slices.Contains(j.Network.SSIDAllow, ssid) {
			return fmt.Sprintf("Waiting for an allowed Wi-Fi: connected to %q", ssid), false
		}
	}
	if ssid != "" && slices.Contains(j.Network.SSIDDeny, ssid) {
		return fmt.Sprintf("Paused on Wi-Fi %q (deny list)", ssid), false
	}
	if p.OnBattery && j.Network.PauseOnBattery {
		return "Waiting for power: on battery", false
	}
	if p.OnBattery && j.Network.MinBatteryPercent != nil && p.BatteryPercent != nil && *p.BatteryPercent < *j.Network.MinBatteryPercent {
		return fmt.Sprintf("Waiting for power: battery at %d%% (minimum %d%%)", *p.BatteryPercent, *j.Network.MinBatteryPercent), false
	}
	return "", true
}

func ifaceName(i string) string {
	switch i {
	case "wifi":
		return "Wi-Fi"
	case "ethernet":
		return "Ethernet"
	case "cellular":
		return "cellular"
	case "", "other":
		return "another network"
	}
	return i
}

// Limit is a bandwidth limit in KiB/s; 0 = unlimited.
type Limit struct{ UpKBps, DownKBps int }

// String renders the limit in rclone --bwlimit syntax ("UP:DOWN").
func (l Limit) String() string {
	if l.UpKBps == 0 && l.DownKBps == 0 {
		return "off"
	}
	f := func(v int) string {
		if v == 0 {
			return "off"
		}
		return fmt.Sprintf("%dKi", v)
	}
	return f(l.UpKBps) + ":" + f(l.DownKBps)
}

// Bandwidth returns the effective global limit: the active timetable
// window combined with the tightest per-job limit of the running jobs.
// rclone's token bucket is process-wide, so per-job limits cannot be
// applied independently.
func Bandwidth(s model.Settings, now time.Time, running []model.Job) Limit {
	var l Limit
	if w := ActiveWindow(s.Network.BwSchedule, now); w != nil {
		l.UpKBps = deref(w.UpKBps)
		l.DownKBps = deref(w.DownKBps)
	}
	for _, j := range running {
		l.UpKBps = tighter(l.UpKBps, deref(j.Limits.BwUpKBps))
		l.DownKBps = tighter(l.DownKBps, deref(j.Limits.BwDownKBps))
	}
	return l
}

// ActiveWindow returns the timetable window covering now, if any.
// Days are 1=Monday..7=Sunday; a window whose "to" is before "from"
// spans midnight.
func ActiveWindow(ws []model.BwWindow, now time.Time) *model.BwWindow {
	now = now.In(time.Local)
	day := int(now.Weekday())
	if day == 0 {
		day = 7
	}
	mins := now.Hour()*60 + now.Minute()
	for i := range ws {
		w := &ws[i]
		from, ok1 := hm(w.From)
		to, ok2 := hm(w.To)
		if !ok1 || !ok2 {
			continue
		}
		if from <= to {
			if slices.Contains(w.Days, day) && mins >= from && mins < to {
				return w
			}
			continue
		}
		prev := day - 1
		if prev == 0 {
			prev = 7
		}
		if (slices.Contains(w.Days, day) && mins >= from) || (slices.Contains(w.Days, prev) && mins < to) {
			return w
		}
	}
	return nil
}

// NextBoundary returns the next time a timetable window starts or ends
// after now (so the daemon can re-apply limits without polling).
func NextBoundary(ws []model.BwWindow, now time.Time) *time.Time {
	var best *time.Time
	now = now.In(time.Local)
	for _, w := range ws {
		for _, s := range []string{w.From, w.To} {
			m, ok := hm(s)
			if !ok {
				continue
			}
			c := time.Date(now.Year(), now.Month(), now.Day(), m/60, m%60, 0, 0, time.Local)
			if !c.After(now) {
				c = c.AddDate(0, 0, 1)
			}
			if best == nil || c.Before(*best) {
				cc := c
				best = &cc
			}
		}
	}
	return best
}

func hm(s string) (int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, false
	}
	return t.Hour()*60 + t.Minute(), true
}

func deref(p *int) int {
	if p == nil || *p < 0 {
		return 0
	}
	return *p
}

func tighter(a, b int) int {
	switch {
	case a == 0:
		return b
	case b == 0:
		return a
	case b < a:
		return b
	}
	return a
}
