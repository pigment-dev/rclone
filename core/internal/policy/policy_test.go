package policy

import (
	"strings"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/model"
)

func state(iface string, ssid string) *model.SystemState {
	st := &model.SystemState{}
	st.Network.Status, st.Network.Interface = "satisfied", iface
	if ssid != "" {
		st.Network.SSID = &ssid
	}
	return st
}

func TestEvaluate(t *testing.T) {
	s := config.DefaultSettings()
	base := config.NewJobDefaults(s)
	if _, ok := Evaluate(base, s, nil); !ok {
		t.Fatal("no system state must allow")
	}
	cases := []struct {
		name   string
		mod    func(*model.Job)
		st     *model.SystemState
		reason string // "" = allowed
	}{
		{"wifi ok", nil, state("wifi", "Home"), ""},
		{"cellular blocked", nil, state("cellular", ""), "Waiting for Wi-Fi: on cellular"},
		{"cellular allowed", func(j *model.Job) { j.Network.AllowCellular = true }, state("cellular", ""), "Waiting for Wi-Fi"}, // settings master switch
		{"wifi only on ethernet", func(j *model.Job) { j.Network.WifiOnly = true }, state("ethernet", ""), "Waiting for Wi-Fi: on Ethernet"},
		{"ssid allow", func(j *model.Job) { j.Network.SSIDAllow = []string{"Home"} }, state("wifi", "Cafe"), `connected to "Cafe"`},
		{"ssid allow match", func(j *model.Job) { j.Network.SSIDAllow = []string{"Home"} }, state("wifi", "Home"), ""},
		{"ssid deny", func(j *model.Job) { j.Network.SSIDDeny = []string{"Hotspot"} }, state("wifi", "Hotspot"), "deny list"},
		{"offline", nil, state("none", ""), "offline"},
	}
	for _, tc := range cases {
		j := base
		if tc.mod != nil {
			tc.mod(&j)
		}
		why, ok := Evaluate(j, s, tc.st)
		if tc.reason == "" && !ok {
			t.Errorf("%s: blocked: %s", tc.name, why)
		}
		if tc.reason != "" && (ok || !strings.Contains(why, tc.reason)) {
			t.Errorf("%s: got (%q,%v) want reason containing %q", tc.name, why, ok, tc.reason)
		}
	}
}

func TestBattery(t *testing.T) {
	s := config.DefaultSettings()
	j := config.NewJobDefaults(s)
	st := state("wifi", "")
	st.Power.OnBattery = true
	st.Power.BatteryPercent = model.Ptr(15)
	j.Network.MinBatteryPercent = model.Ptr(20)
	if why, ok := Evaluate(j, s, st); ok || !strings.Contains(why, "15%") {
		t.Errorf("got %q %v", why, ok)
	}
	j.Network.MinBatteryPercent = nil
	j.Network.PauseOnBattery = true
	if why, ok := Evaluate(j, s, st); ok || why != "Waiting for power: on battery" {
		t.Errorf("got %q %v", why, ok)
	}
}

func TestBandwidth(t *testing.T) {
	s := config.DefaultSettings()
	s.Network.BwSchedule = []model.BwWindow{
		{Days: []int{1, 2, 3, 4, 5}, From: "09:00", To: "18:00", UpKBps: model.Ptr(512), DownKBps: model.Ptr(2048)},
		{Days: []int{5}, From: "22:00", To: "06:00", UpKBps: model.Ptr(100)},
	}
	fri := func(hm string) time.Time {
		t, _ := time.ParseInLocation("2006-01-02 15:04", "2026-10-23 "+hm, time.Local)
		return t
	}
	if l := Bandwidth(s, fri("10:00"), nil); l.UpKBps != 512 || l.DownKBps != 2048 {
		t.Errorf("work hours: %+v", l)
	}
	if l := Bandwidth(s, fri("20:00"), nil); l.String() != "off" {
		t.Errorf("evening: %+v", l)
	}
	if l := Bandwidth(s, fri("23:00"), nil); l.UpKBps != 100 {
		t.Errorf("overnight window: %+v", l)
	}
	sat := fri("03:00").AddDate(0, 0, 1)
	if l := Bandwidth(s, sat, nil); l.UpKBps != 100 {
		t.Errorf("overnight spill into saturday: %+v", l)
	}
	j := config.NewJobDefaults(s)
	j.Limits.BwUpKBps = model.Ptr(256)
	if l := Bandwidth(s, fri("10:00"), []model.Job{j}); l.UpKBps != 256 || l.String() != "256Ki:2048Ki" {
		t.Errorf("tighter job limit: %+v %s", l, l)
	}
	if NextBoundary(s.Network.BwSchedule, fri("10:00")) == nil {
		t.Error("expected a next boundary")
	}
}
