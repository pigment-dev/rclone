package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/client"
	"github.com/pigment-dev/rclone/core/internal/ipc"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/paths"
)

func shortTemp(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("", "pdr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	d, _ = filepath.EvalSymlinks(d)
	return d
}

func writeFile(t *testing.T, p, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

type harness struct {
	t *testing.T
	c *client.Client
}

func (h *harness) call(method string, params, out any) {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := h.c.Call(ctx, method, params, out); err != nil {
		h.t.Fatalf("%s: %v", method, err)
	}
}

// waitRun waits until the job's last run is runID and the job is idle.
func (h *harness) waitRun(jobID, runID string) model.RunSummary {
	h.t.Helper()
	deadline := time.Now().Add(time.Minute)
	for time.Now().Before(deadline) {
		var res struct {
			Job model.Job `json:"job"`
		}
		h.call("jobs.get", map[string]any{"id": jobID}, &res)
		st := res.Job.Status
		if st.State != model.StateRunning && st.State != model.StateQueued && st.LastRun != nil && st.LastRun.ID == runID {
			return *st.LastRun
		}
		time.Sleep(50 * time.Millisecond)
	}
	h.t.Fatalf("run %s of %s did not finish", runID, jobID)
	return model.RunSummary{}
}

func TestEndToEndOverSocket(t *testing.T) {
	home := shortTemp(t)
	p, err := paths.Resolve(home, "")
	if err != nil {
		t.Fatal(err)
	}
	d, err := New(Options{Paths: p, LogLevel: "info"})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	defer d.Stop()

	// The hello gate rejects anything first.
	raw, err := ipc.Dial(context.Background(), p.Socket)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = raw.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"jobs.list","params":{}}` + "\n"))
	line, err := bufio.NewReader(raw).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var gate api.Response
	_ = json.Unmarshal(line, &gate)
	if gate.Error == nil || gate.Error.Code != api.CodeNoHello {
		t.Fatalf("hello gate: %s", line)
	}
	_ = raw.Close()

	c, err := client.Dial(context.Background(), p.Socket, "test")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	h := &harness{t: t, c: c}
	if c.Hello["protocol"].(float64) != 1 || c.Hello["rcloneVersion"] == "" {
		t.Errorf("hello = %v", c.Hello)
	}
	err = c.Call(context.Background(), "no.such.method", nil, nil)
	var apiErr *api.Error
	if !errors.As(err, &apiErr) || apiErr.Code != api.CodeMethodNotFound {
		t.Errorf("unknown method: %v", err)
	}

	var provs struct {
		Providers []model.Provider `json:"providers"`
	}
	h.call("accounts.providers", nil, &provs)
	if len(provs.Providers) != 15 {
		t.Errorf("providers = %d, want 15", len(provs.Providers))
	}

	// A key-based ("fields") account completes immediately.
	var add struct {
		State   string        `json:"state"`
		Account model.Account `json:"account"`
	}
	h.call("accounts.add.start", map[string]any{"provider": "local", "name": "Disk", "fields": map[string]any{}}, &add)
	if add.State != "done" || !strings.HasPrefix(add.Account.Remote, "pd_acc_") {
		t.Fatalf("add = %+v", add)
	}
	var tr struct {
		OK bool `json:"ok"`
	}
	h.call("accounts.test", map[string]any{"id": add.Account.ID}, &tr)
	if !tr.OK {
		t.Error("local account test failed")
	}

	base := shortTemp(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	writeFile(t, filepath.Join(local, "shared.txt"), "v1")
	writeFile(t, filepath.Join(local, ".git", "HEAD"), "ref")
	writeFile(t, filepath.Join(remote, "from-cloud.txt"), "cloud")

	var created struct {
		Job model.Job `json:"job"`
	}
	h.call("jobs.create", map[string]any{"job": map[string]any{
		"name": "Two-way", "localPath": local, "accountId": add.Account.ID, "remotePath": remote,
		"direction": "twoWay", "conflictPolicy": "ask", "deletePolicy": "archive",
		"safety": map[string]any{"maxDeletePercent": 50, "dryRunFirst": false}, "filters": map[string]any{"minAgeSec": 0},
	}}, &created)
	jid := created.Job.ID
	if created.Job.Status.State != model.StateNeedsBaseline {
		t.Fatalf("new two-way job state = %s", created.Job.Status.State)
	}
	err = c.Call(context.Background(), "jobs.run", map[string]any{"id": jid}, nil)
	if !errors.As(err, &apiErr) || apiErr.Code != api.CodeConflict {
		t.Errorf("run without baseline should be refused: %v", err)
	}

	var ex struct {
		Included bool    `json:"included"`
		Rule     *string `json:"rule"`
	}
	h.call("jobs.explain", map[string]any{"id": jid, "path": ".git/HEAD"}, &ex)
	if ex.Included || ex.Rule == nil || !strings.Contains(*ex.Rule, "vcs") {
		t.Errorf("explain .git/HEAD = %+v", ex)
	}

	var prev model.Preview
	h.call("jobs.preview", map[string]any{"id": jid}, &prev)
	if prev.Adds != 2 || prev.Excluded < 1 {
		t.Errorf("preview = %+v", prev)
	}

	var run struct {
		RunID string `json:"runId"`
	}
	h.call("jobs.run", map[string]any{"id": jid, "resync": true}, &run)
	if sum := h.waitRun(jid, run.RunID); !sum.OK {
		t.Fatalf("baseline failed: %v", *sum.Error)
	}
	if _, err := os.Stat(filepath.Join(local, "from-cloud.txt")); err != nil {
		t.Fatal("baseline did not download")
	}

	// Conflict: both sides edit the same file.
	time.Sleep(1100 * time.Millisecond)
	writeFile(t, filepath.Join(local, "shared.txt"), "mine")
	writeFile(t, filepath.Join(remote, "shared.txt"), "theirs!")
	h.call("jobs.run", map[string]any{"id": jid}, &run)
	sum := h.waitRun(jid, run.RunID)
	if !sum.OK || sum.Conflicts != 1 {
		t.Fatalf("conflict run = %+v", sum)
	}
	var acts struct {
		Actions []model.Action `json:"actions"`
	}
	h.call("actions.list", nil, &acts)
	var conflict *model.Action
	for i := range acts.Actions {
		if acts.Actions[i].Kind == model.ActConflict {
			conflict = &acts.Actions[i]
		}
	}
	if conflict == nil || conflict.Path == nil || *conflict.Path != "shared.txt" {
		t.Fatalf("no conflict action: %+v", acts.Actions)
	}
	var resolved struct {
		Action model.Action `json:"action"`
	}
	h.call("actions.resolve", map[string]any{"id": conflict.ID, "choice": "keepRemote"}, &resolved)
	if !resolved.Action.Resolved {
		t.Error("action not resolved")
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		b, _ := os.ReadFile(filepath.Join(remote, "shared.txt"))
		l, _ := os.ReadFile(filepath.Join(local, "shared.txt"))
		if string(b) == "theirs!" && string(l) == "theirs!" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("keepRemote not applied: local=%q remote=%q", l, b)
		}
		time.Sleep(100 * time.Millisecond)
	}

	// One-way mirror with the delete guard.
	src, dst := filepath.Join(base, "s"), filepath.Join(base, "d")
	for _, n := range []string{"1", "2", "3", "4"} {
		writeFile(t, filepath.Join(src, n+".txt"), n)
	}
	h.call("jobs.create", map[string]any{"job": map[string]any{
		"name": "Mirror", "localPath": src, "accountId": add.Account.ID, "remotePath": dst,
		"direction": "upload", "deletePolicy": "mirror", "safety": map[string]any{"maxDeletePercent": 25}, "filters": map[string]any{"minAgeSec": 0},
	}}, &created)
	mid := created.Job.ID
	h.call("jobs.run", map[string]any{"id": mid}, &run)
	if s := h.waitRun(mid, run.RunID); !s.OK || s.Files != 4 {
		t.Fatalf("mirror run = %+v", s)
	}
	for _, n := range []string{"1", "2", "3"} {
		_ = os.Remove(filepath.Join(src, n+".txt"))
	}
	h.call("jobs.run", map[string]any{"id": mid}, &run)
	if s := h.waitRun(mid, run.RunID); s.OK {
		t.Fatal("delete guard did not trip")
	}
	var job struct {
		Job model.Job `json:"job"`
	}
	h.call("jobs.get", map[string]any{"id": mid}, &job)
	if job.Job.Status.State != model.StateError {
		t.Errorf("state after guard = %s", job.Job.Status.State)
	}
	h.call("actions.list", nil, &acts)
	var guard *model.Action
	for i := range acts.Actions {
		if acts.Actions[i].Kind == model.ActMaxDeleteAbort {
			guard = &acts.Actions[i]
		}
	}
	if guard == nil {
		t.Fatal("no maxDeleteAbort action")
	}
	if _, err := os.Stat(filepath.Join(dst, "1.txt")); err != nil {
		t.Fatal("guard must not delete")
	}
	h.call("actions.resolve", map[string]any{"id": guard.ID, "choice": "runAnyway"}, &resolved)
	deadline = time.Now().Add(30 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dst, "1.txt")); os.IsNotExist(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("run anyway did not delete")
		}
		time.Sleep(100 * time.Millisecond)
	}

	// Notifications arrived for state changes.
	gotState := false
	for len(c.Notify) > 0 {
		if n := <-c.Notify; n.Method == "job.state" {
			gotState = true
		}
	}
	if !gotState {
		t.Error("no job.state notifications received")
	}

	var logs struct {
		Lines []model.LogLine `json:"lines"`
	}
	h.call("log.query", map[string]any{"jobId": mid, "limit": 50}, &logs)
	if len(logs.Lines) == 0 {
		t.Error("no log lines for the mirror job")
	}
	var info map[string]any
	h.call("daemon.info", nil, &info)
	if info["rssBytes"].(float64) <= 0 {
		t.Error("rssBytes missing")
	}
	var hist struct {
		Runs []model.RunSummary `json:"runs"`
	}
	h.call("jobs.history", map[string]any{"id": mid}, &hist)
	if len(hist.Runs) < 2 {
		t.Errorf("history = %d runs", len(hist.Runs))
	}
	err = c.Call(context.Background(), "accounts.remove", map[string]any{"id": add.Account.ID}, nil)
	if !errors.As(err, &apiErr) || apiErr.Code != api.CodeConflict {
		t.Errorf("remove in-use account: %v", err)
	}
}
