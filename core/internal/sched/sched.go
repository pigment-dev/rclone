// Package sched computes when scheduled jobs are due.
package sched

import (
	"errors"
	"fmt"
	"time"

	"github.com/robfig/cron/v3"

	"github.com/pigment-dev/rclone/core/internal/model"
)

var parser = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)

// ValidateTriggers checks trigger syntax.
func ValidateTriggers(t model.Triggers) error {
	if t.IntervalMin != nil && *t.IntervalMin < 1 {
		return errors.New("triggers.intervalMin must be >= 1")
	}
	if t.Daily != nil {
		if _, _, err := parseHM(*t.Daily); err != nil {
			return fmt.Errorf("triggers.daily: %w", err)
		}
	}
	if t.Weekly != nil {
		if t.Weekly.Day < 1 || t.Weekly.Day > 7 {
			return errors.New("triggers.weekly.day must be 1 (Monday) .. 7 (Sunday)")
		}
		if _, _, err := parseHM(t.Weekly.Time); err != nil {
			return fmt.Errorf("triggers.weekly.time: %w", err)
		}
	}
	if t.Cron != nil && *t.Cron != "" {
		if _, err := parser.Parse(*t.Cron); err != nil {
			return fmt.Errorf("triggers.cron: %w", err)
		}
	}
	if t.DebounceSec < 0 || t.DebounceSec > 3600 {
		return errors.New("triggers.debounceSec must be 0-3600")
	}
	return nil
}

func parseHM(s string) (int, int, error) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, 0, errors.New("want HH:MM")
	}
	return t.Hour(), t.Minute(), nil
}

// HasSchedule reports whether any time-based trigger is set.
func HasSchedule(t model.Triggers) bool {
	return t.IntervalMin != nil || t.Daily != nil || t.Weekly != nil || (t.Cron != nil && *t.Cron != "")
}

// Next returns the next due time of the time-based triggers, computed
// from the last run start (anchor). When anchor is zero, schedules are
// computed from now. A result <= now means the run is due (missed-run
// catch-up). Returns nil when no time-based trigger is set.
func Next(t model.Triggers, anchor, now time.Time) *time.Time {
	from := anchor
	if from.IsZero() {
		from = now
	}
	var best time.Time
	consider := func(c time.Time) {
		if !c.IsZero() && (best.IsZero() || c.Before(best)) {
			best = c
		}
	}
	if t.IntervalMin != nil && *t.IntervalMin > 0 {
		consider(from.Add(time.Duration(*t.IntervalMin) * time.Minute))
	}
	if t.Daily != nil {
		if h, m, err := parseHM(*t.Daily); err == nil {
			consider(nextDaily(from, h, m))
		}
	}
	if t.Weekly != nil {
		if h, m, err := parseHM(t.Weekly.Time); err == nil {
			consider(nextWeekly(from, t.Weekly.Day, h, m))
		}
	}
	if t.Cron != nil && *t.Cron != "" {
		if s, err := parser.Parse(*t.Cron); err == nil {
			consider(s.Next(from.In(time.Local)))
		}
	}
	if best.IsZero() {
		return nil
	}
	b := best.UTC()
	return &b
}

func nextDaily(from time.Time, h, m int) time.Time {
	l := from.In(time.Local)
	c := time.Date(l.Year(), l.Month(), l.Day(), h, m, 0, 0, time.Local)
	if !c.After(l) {
		c = time.Date(l.Year(), l.Month(), l.Day()+1, h, m, 0, 0, time.Local)
	}
	return c
}

// nextWeekly: day 1=Monday .. 7=Sunday.
func nextWeekly(from time.Time, day, h, m int) time.Time {
	l := from.In(time.Local)
	want := time.Weekday(day % 7) // 7 → Sunday(0)
	for i := 0; i <= 7; i++ {
		d := time.Date(l.Year(), l.Month(), l.Day()+i, h, m, 0, 0, time.Local)
		if d.Weekday() == want && d.After(l) {
			return d
		}
	}
	return time.Date(l.Year(), l.Month(), l.Day()+7, h, m, 0, 0, time.Local)
}

// Backoff returns the retry delay after n consecutive failures (n >= 1).
func Backoff(n int) time.Duration {
	steps := []time.Duration{time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour}
	if n < 1 {
		return 0
	}
	if n > len(steps) {
		n = len(steps)
	}
	return steps[n-1]
}
