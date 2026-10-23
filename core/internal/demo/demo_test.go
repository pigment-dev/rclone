package demo_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/client"
	"github.com/pigment-dev/rclone/core/internal/daemon"
	"github.com/pigment-dev/rclone/core/internal/demo"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/paths"
)

func TestDemoMode(t *testing.T) {
	home, err := os.MkdirTemp("", "pdr")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(home) }()
	p, _ := paths.Resolve(home, "")
	if err := demo.Seed(p); err != nil {
		t.Fatal(err)
	}
	eng := demo.NewEngine()
	d, err := daemon.New(daemon.Options{Paths: p, Demo: true, Engine: eng, Flow: demo.NewFlow()})
	if err != nil {
		t.Fatal(err)
	}
	d.SetSystemState(demo.SystemState())
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	defer d.Stop()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go demo.Loop(ctx, d, eng)

	c, err := client.Dial(ctx, p.Socket, "mac")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	var res struct {
		Jobs []model.Job `json:"jobs"`
	}
	deadline := time.Now().Add(5 * time.Second)
	var states map[string]string
	for time.Now().Before(deadline) {
		if err := c.Call(ctx, "jobs.list", nil, &res); err != nil {
			t.Fatal(err)
		}
		states = map[string]string{}
		for _, j := range res.Jobs {
			states[j.ID] = j.Status.State
		}
		if states[demo.JobProjects] == model.StateRunning {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	want := map[string]string{
		demo.JobProjects: model.StateRunning, demo.JobDocuments: model.StateIdle, demo.JobWebsite: model.StateError,
		demo.JobNAS: model.StateWaiting, demo.JobNotes: model.StateNeedsBaseline,
	}
	for id, st := range want {
		if states[id] != st {
			t.Errorf("%s: state %q, want %q", id, states[id], st)
		}
	}
	var acts struct {
		Actions []model.Action `json:"actions"`
	}
	if err := c.Call(ctx, "actions.list", nil, &acts); err != nil || len(acts.Actions) != 3 {
		t.Errorf("actions = %d (%v)", len(acts.Actions), err)
	}
	var logs struct {
		Lines []model.LogLine `json:"lines"`
	}
	if err := c.Call(ctx, "log.query", map[string]any{"limit": 100}, &logs); err != nil || len(logs.Lines) < 30 {
		t.Errorf("log lines = %d (%v)", len(logs.Lines), err)
	}
	// Progress and the overall aggregate stream while the upload runs.
	gotJob, gotOverall := false, false
	timeout := time.After(5 * time.Second)
	for !(gotJob && gotOverall) {
		select {
		case n := <-c.Notify:
			gotJob = gotJob || n.Method == "job.progress"
			gotOverall = gotOverall || n.Method == "overall.progress"
		case <-timeout:
			t.Fatalf("progress notifications: job=%v overall=%v", gotJob, gotOverall)
		}
	}
}
