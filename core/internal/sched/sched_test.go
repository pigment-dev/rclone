package sched

import (
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

func local(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04", s, time.Local)
	if err != nil {
		panic(err)
	}
	return t
}

func TestNextInterval(t *testing.T) {
	anchor := local("2026-10-23 10:00")
	n := Next(model.Triggers{IntervalMin: model.Ptr(30)}, anchor, anchor.Add(5*time.Minute))
	if n == nil || !n.Equal(anchor.Add(30*time.Minute)) {
		t.Fatalf("got %v", n)
	}
}

func TestNextDailyWeeklyCron(t *testing.T) {
	now := local("2026-10-23 10:00") // a Friday
	cases := []struct {
		name string
		tr   model.Triggers
		want time.Time
	}{
		{"daily later today", model.Triggers{Daily: model.Ptr("18:30")}, local("2026-10-23 18:30")},
		{"daily tomorrow", model.Triggers{Daily: model.Ptr("09:00")}, local("2026-10-24 09:00")},
		{"weekly monday", model.Triggers{Weekly: &model.Weekly{Day: 1, Time: "08:00"}}, local("2026-10-26 08:00")},
		{"weekly sunday=7", model.Triggers{Weekly: &model.Weekly{Day: 7, Time: "21:00"}}, local("2026-10-25 21:00")},
		{"cron every 2h", model.Triggers{Cron: model.Ptr("0 */2 * * *")}, local("2026-10-23 12:00")},
		{"earliest wins", model.Triggers{Daily: model.Ptr("23:00"), IntervalMin: model.Ptr(60)}, local("2026-10-23 11:00")},
	}
	for _, tc := range cases {
		got := Next(tc.tr, now, now)
		if got == nil || !got.Equal(tc.want) {
			t.Errorf("%s: got %v want %v", tc.name, got, tc.want)
		}
	}
	if Next(model.Triggers{OnChange: true, Manual: true}, now, now) != nil {
		t.Error("no time trigger should give nil")
	}
}

func TestMissedRunCatchUp(t *testing.T) {
	last := local("2026-10-20 09:00")
	now := local("2026-10-23 10:00")
	n := Next(model.Triggers{Daily: model.Ptr("09:30")}, last, now)
	if n == nil || n.After(now) {
		t.Fatalf("missed daily run should be due now, got %v", n)
	}
}

func TestValidate(t *testing.T) {
	bad := []model.Triggers{
		{Daily: model.Ptr("25:00")},
		{Weekly: &model.Weekly{Day: 8, Time: "09:00"}},
		{Cron: model.Ptr("not a cron")},
		{IntervalMin: model.Ptr(0)},
	}
	for _, tr := range bad {
		if ValidateTriggers(tr) == nil {
			t.Errorf("accepted %+v", tr)
		}
	}
	if err := ValidateTriggers(model.Triggers{Cron: model.Ptr("@hourly"), Daily: model.Ptr("07:15")}); err != nil {
		t.Error(err)
	}
}

func TestBackoff(t *testing.T) {
	want := []time.Duration{time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour, time.Hour}
	for i, w := range want {
		if got := Backoff(i + 1); got != w {
			t.Errorf("Backoff(%d) = %v want %v", i+1, got, w)
		}
	}
}
