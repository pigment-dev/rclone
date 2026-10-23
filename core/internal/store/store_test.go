package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

func TestLogsQuery(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	job := "job_a"
	base := time.Now().Add(-time.Hour).UTC()
	for i := range 50 {
		l := model.LogLine{TS: base.Add(time.Duration(i) * time.Second), Level: "info", Msg: "copied file"}
		if i%10 == 0 {
			l.Level, l.JobID, l.Msg = "error", &job, "failed: token = {\"access_token\":\"abc123\"}"
		}
		s.AddLog(l)
	}
	ctx := context.Background()
	lines, err := s.QueryLogs(ctx, LogQuery{Level: "warn"})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 5 {
		t.Fatalf("got %d warn+ lines, want 5", len(lines))
	}
	if !lines[0].TS.After(lines[1].TS) {
		t.Error("lines must be newest first")
	}
	if strings.Contains(lines[0].Msg, "abc123") {
		t.Errorf("secret not redacted: %s", lines[0].Msg)
	}
	lines, _ = s.QueryLogs(ctx, LogQuery{JobID: job, Limit: 2})
	if len(lines) != 2 || *lines[0].JobID != job {
		t.Errorf("job filter/limit broken: %+v", lines)
	}
	before := lines[1].TS
	older, _ := s.QueryLogs(ctx, LogQuery{JobID: job, Before: &before})
	if len(older) != 3 {
		t.Errorf("before cursor: got %d want 3", len(older))
	}
	hits, _ := s.QueryLogs(ctx, LogQuery{Search: "100%_"})
	if len(hits) != 0 {
		t.Error("LIKE wildcards must be escaped")
	}
	if err := s.Prune(ctx, 30*time.Minute); err != nil {
		t.Fatal(err)
	}
	if all, _ := s.QueryLogs(ctx, LogQuery{}); len(all) != 0 {
		t.Errorf("prune left %d lines", len(all))
	}
}

func TestRunsAndActions(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	end := now.Add(time.Minute)
	_ = s.PutRun(ctx, "job_a", model.RunSummary{ID: "run_1", StartedAt: now.Add(-time.Hour), EndedAt: &end, OK: true, Bytes: 10})
	_ = s.PutRun(ctx, "job_a", model.RunSummary{ID: "run_2", StartedAt: now, Error: model.Ptr("boom")})
	runs, _ := s.Runs(ctx, "job_a", 10)
	if len(runs) != 2 || runs[0].ID != "run_2" || runs[1].EndedAt == nil {
		t.Fatalf("runs = %+v", runs)
	}
	if lr := s.LastRun(ctx, "job_a"); lr == nil || lr.OK || *lr.Error != "boom" {
		t.Errorf("last run = %+v", lr)
	}
	jid := "job_a"
	a := model.Action{ID: "act_1", JobID: &jid, Kind: model.ActConflict, Severity: "warning", Title: "t", Message: "m", CreatedAt: now,
		Choices: []model.Choice{{ID: "keepLocal", Label: "L"}}, Data: map[string]string{"path": "x"}}
	if err := s.PutAction(ctx, a); err != nil {
		t.Fatal(err)
	}
	open, _ := s.OpenActions(ctx, jid, model.ActConflict)
	if len(open) != 1 || open[0].Data["path"] != "x" || open[0].Choices[0].ID != "keepLocal" {
		t.Fatalf("open = %+v", open)
	}
	a.Resolved = true
	_ = s.PutAction(ctx, a)
	if as, _ := s.Actions(ctx, false); len(as) != 0 {
		t.Error("resolved action listed as open")
	}
	if as, _ := s.Actions(ctx, true); len(as) != 1 {
		t.Error("includeResolved lost the action")
	}
}

func TestRedact(t *testing.T) {
	cases := []string{
		`token = {"access_token":"ya29.secret","expiry":"2026"}`,
		`Authorization: Bearer abcdefghijklmnopqrstuvwxyz`,
		`dial sftp://alex:hunter2@nas.local/volume1`,
		`GET https://x/auth?code=4/0Abcdef&state=xyz`,
		`secret_access_key = AKIAQWERTY`,
	}
	for _, c := range cases {
		out := Redact(c)
		for _, secret := range []string{"ya29.secret", "abcdefghijklmnop", "hunter2", "4/0Abcdef", "AKIAQWERTY"} {
			if strings.Contains(out, secret) {
				t.Errorf("Redact(%q) = %q leaks %q", c, out, secret)
			}
		}
	}
}
