package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/policy"
	"github.com/pigment-dev/rclone/core/internal/sched"
)

// runReq is a request to run a job.
type runReq struct {
	RunID  string
	DryRun bool
	Resync bool
	Force  bool
	Manual bool
	Files  []string // nil = full run
	Reason string
}

// merge combines two pending requests into one run.
func merge(a, b *runReq) *runReq {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	out := *a
	out.DryRun = a.DryRun && b.DryRun
	out.Resync = a.Resync || b.Resync
	out.Force = a.Force || b.Force
	out.Manual = a.Manual || b.Manual
	if a.Files == nil || b.Files == nil {
		out.Files = nil
	} else {
		out.Files = append(append([]string(nil), a.Files...), b.Files...)
		slices.Sort(out.Files)
		out.Files = slices.Compact(out.Files)
	}
	return &out
}

type activeRun struct {
	id      string
	req     runReq
	cancel  context.CancelFunc
	started time.Time
	blocked bool // cancelled by policy; re-queue when allowed
}

// jobRT is the in-memory runtime of a job (guarded by Daemon.mu).
type jobRT struct {
	id            string
	run           *activeRun
	queued        *runReq
	pending       *runReq // arrived while running
	waiting       *runReq // blocked by policy (offline queue)
	lastRun       *model.RunSummary
	progress      *model.Progress
	failures      int
	retryAt       *time.Time
	lastErr       string
	nextRun       *time.Time
	lastPublished string
}

func (d *Daemon) newRT(j model.Job) *jobRT {
	rt := &jobRT{id: j.ID}
	rt.lastRun = d.db.LastRun(context.Background(), j.ID)
	if rt.lastRun != nil && !rt.lastRun.OK && rt.lastRun.Error != nil && !strings.Contains(*rt.lastRun.Error, "context canceled") {
		rt.failures, rt.lastErr = 1, *rt.lastRun.Error
	}
	return rt
}

// statusLocked computes the JobStatus. Caller holds d.mu.
func (d *Daemon) statusLocked(rt *jobRT, j model.Job) model.JobStatus {
	st := model.JobStatus{State: model.StateIdle, LastRun: rt.lastRun, NextRun: rt.nextRun}
	r := d.cfg.Runtime(j.ID)
	reason := func(s string) { st.Reason = &s }
	switch {
	case rt.run != nil:
		st.State = model.StateRunning
		st.Progress = rt.progress
		if rt.run.req.Resync {
			reason("Building two-way baseline")
		} else if rt.run.req.DryRun {
			reason("Dry run")
		}
	case rt.queued != nil:
		st.State = model.StateQueued
		reason("Waiting for another sync to finish")
	case r.Paused:
		st.State = model.StatePaused
	case d.pausedAll:
		st.State = model.StatePaused
		if d.pauseAllUntil != nil {
			reason("All syncs paused until " + d.pauseAllUntil.Local().Format("15:04"))
		} else {
			reason("All syncs paused")
		}
	case !j.Enabled:
		reason("Disabled")
	case j.Direction == model.DirTwoWay && r.NeedsBaseline:
		st.State = model.StateNeedsBaseline
		reason("Two-way sync needs a baseline: review the preview, then run a resync")
	default:
		if why, ok := policy.Evaluate(j, d.cfg.Settings(), d.sys); !ok {
			st.State = model.StateWaiting
			reason(why)
		} else if rt.failures > 0 {
			st.State = model.StateError
			reason(rt.lastErr)
		} else if j.Safety.DryRunFirst && !r.PreviewDone && sched.HasSchedule(j.Triggers) {
			reason("Run a preview before the first scheduled sync")
		}
	}
	return st
}

// publishStateLocked sends job.state when the status changed.
func (d *Daemon) publishStateLocked(rt *jobRT) {
	j, ok := d.cfg.Job(rt.id)
	if !ok {
		return
	}
	st := d.statusLocked(rt, j)
	cmp := st
	cmp.Progress = nil
	b, _ := json.Marshal(cmp)
	if string(b) == rt.lastPublished {
		return
	}
	rt.lastPublished = string(b)
	d.srv.Publish("job.state", map[string]any{"jobId": rt.id, "status": st})
}

func (d *Daemon) publishAllLocked() {
	for _, rt := range d.jobs {
		d.publishStateLocked(rt)
	}
}

// jobView returns a job with its status.
func (d *Daemon) jobView(j model.Job) model.Job {
	d.mu.Lock()
	defer d.mu.Unlock()
	if rt := d.jobs[j.ID]; rt != nil {
		st := d.statusLocked(rt, j)
		j.Status = &st
	} else {
		j.Status = &model.JobStatus{State: model.StateIdle}
	}
	return j
}

// TriggerRun requests a run. Manual requests return policy/conflict errors.
func (d *Daemon) TriggerRun(id string, req runReq) (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.triggerLocked(id, req)
}

func (d *Daemon) triggerLocked(id string, req runReq) (string, error) {
	rt := d.jobs[id]
	j, ok := d.cfg.Job(id)
	if rt == nil || !ok {
		return "", api.Errorf(api.CodeNotFound, "job %s not found", id)
	}
	r := d.cfg.Runtime(id)
	refuse := func(code int, format string, args ...any) (string, error) {
		if req.Manual {
			return "", api.Errorf(code, format, args...)
		}
		return "", nil
	}
	if !j.Enabled && !req.Manual {
		return "", nil
	}
	if r.Paused || d.pausedAll {
		return refuse(api.CodeConflict, "job is paused")
	}
	if j.Direction == model.DirTwoWay && r.NeedsBaseline && !req.Resync && !req.DryRun {
		return refuse(api.CodeConflict, "two-way job needs a baseline first: run it with resync")
	}
	if !req.Manual && !req.DryRun && j.Safety.DryRunFirst && !r.PreviewDone {
		return "", nil
	}
	if why, ok := policy.Evaluate(j, d.cfg.Settings(), d.sys); !ok {
		if req.Manual {
			return "", api.Errorf(api.CodePolicy, "%s", why)
		}
		rt.waiting = merge(rt.waiting, &req)
		d.publishStateLocked(rt)
		return "", nil
	}
	if rt.run != nil {
		if req.Manual && !req.DryRun {
			return rt.run.id, api.Errorf(api.CodeConflict, "job is already running")
		}
		rt.pending = merge(rt.pending, &req)
		return rt.run.id, nil
	}
	if rt.queued != nil {
		rt.queued = merge(rt.queued, &req)
		return rt.queued.RunID, nil
	}
	if req.RunID == "" {
		req.RunID = accounts.NewID("run")
	}
	rt.queued = &req
	d.queue = append(d.queue, id)
	d.pumpLocked()
	d.publishStateLocked(rt)
	return req.RunID, nil
}

// pumpLocked starts queued runs while slots are free.
func (d *Daemon) pumpLocked() {
	for d.running < MaxConcurrentRuns && len(d.queue) > 0 {
		id := d.queue[0]
		d.queue = d.queue[1:]
		rt := d.jobs[id]
		if rt == nil || rt.queued == nil || rt.run != nil {
			continue
		}
		req := *rt.queued
		rt.queued = nil
		d.startLocked(rt, req)
	}
}

func (d *Daemon) startLocked(rt *jobRT, req runReq) {
	j, _ := d.cfg.Job(rt.id)
	acc, ok := d.cfg.Account(j.AccountID)
	ctx, cancel := context.WithCancel(d.ctx)
	rt.run = &activeRun{id: req.RunID, req: req, cancel: cancel, started: time.Now().UTC()}
	rt.progress = &model.Progress{Transferring: []model.Transfer{}}
	d.running++
	d.publishStateLocked(rt)
	go d.applyBandwidth() // per-job limits change the global bucket
	spec := engine.RunSpec{
		RunID:   req.RunID,
		Job:     j,
		Remote:  acc.Remote,
		WorkDir: filepath.Join(d.opt.Paths.DataDir, "bisync", j.ID),
		DryRun:  req.DryRun,
		Resync:  req.Resync,
		Force:   req.Force,
		Files:   req.Files,
		Now:     time.Now(),
	}
	started := rt.run.started
	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		defer cancel()
		var res engine.RunResult
		if !ok {
			res = engine.RunResult{Err: fmt.Errorf("account %s not found", j.AccountID), Fail: engine.FailOther}
		} else if c, err := filters.Compile(j.Filters, filters.Options{LocalRoot: j.LocalPath}); err != nil {
			res = engine.RunResult{Err: err, Fail: engine.FailOther}
		} else {
			spec.Filter = c
			res = d.execute(ctx, spec, req)
		}
		d.finish(j, req, started, res)
	}()
}

func (d *Daemon) execute(ctx context.Context, spec engine.RunSpec, req runReq) engine.RunResult {
	jid, rid := spec.Job.ID, spec.RunID
	started := time.Now().UTC()
	_ = d.db.PutRun(ctx, jid, model.RunSummary{ID: rid, StartedAt: started, DryRun: req.DryRun})
	kind := "full sync"
	switch {
	case req.Resync:
		kind = "two-way baseline (resync)"
	case req.Files != nil:
		kind = fmt.Sprintf("quick sync of %d changed file(s)", len(req.Files))
	}
	if req.DryRun {
		kind = "dry run"
	}
	d.logf("notice", &jid, &rid, "Started %s of %q (%s)", kind, spec.Job.Name, req.Reason)
	return d.eng.Run(ctx, spec, func(p model.Progress) { d.onProgress(jid, rid, p) })
}

// finish records the outcome and moves the job to its next state.
func (d *Daemon) finish(j model.Job, req runReq, started time.Time, res engine.RunResult) {
	jid, rid := j.ID, req.RunID
	ended := time.Now().UTC()
	sum := model.RunSummary{ID: rid, StartedAt: started, EndedAt: &ended, OK: res.Err == nil, Bytes: res.Bytes, Files: res.Files,
		Deletes: res.Deletes, Conflicts: int64(len(res.Conflicts)), DryRun: req.DryRun}
	if res.Err != nil {
		e := res.Err.Error()
		sum.Error = &e
	}
	if err := d.db.PutRun(context.Background(), jid, sum); err != nil {
		d.health(false, "history database write failed: "+err.Error())
	}
	if res.Err == nil {
		d.logf("notice", &jid, &rid, "Finished %q: %d file(s), %s, %d deleted, %d conflict(s) in %s", j.Name, res.Files, humanBytes(res.Bytes), res.Deletes, len(res.Conflicts), ended.Sub(started).Round(time.Second))
	} else if res.Fail != engine.FailCancelled {
		d.logf("error", &jid, &rid, "Failed %q: %v", j.Name, res.Err)
	} else {
		d.logf("info", &jid, &rid, "Stopped %q", j.Name)
	}

	// Persistent runtime updates.
	_ = d.cfg.UpdateRuntime(jid, func(r *config.JobRuntime) {
		if res.Err == nil {
			r.PreviewDone = true
			if req.Resync {
				r.NeedsBaseline = false
			}
			if req.Files == nil && !req.DryRun {
				r.LastFullReconcile = ended.Format(time.RFC3339)
			}
		}
		if res.Fail == engine.FailNeedsResync {
			r.NeedsBaseline = true
		}
	})

	// Action Center items exist before clients see the final state.
	d.recordOutcome(j, req, res)

	d.mu.Lock()
	d.running--
	rt := d.jobs[jid]
	var blocked bool
	if rt != nil {
		blocked = rt.run != nil && rt.run.blocked
		rt.run, rt.progress = nil, nil
		if res.Fail != engine.FailCancelled {
			rt.lastRun = &sum
		}
		switch {
		case res.Err == nil:
			rt.failures, rt.lastErr, rt.retryAt = 0, "", nil
		case res.Fail == engine.FailCancelled:
			if blocked {
				rt.waiting = merge(rt.waiting, &req)
			}
		case res.Fail == engine.FailNeedsResync, res.Fail == engine.FailMaxDelete, res.Fail == engine.FailPathTooLong:
			rt.failures, rt.lastErr, rt.retryAt = rt.failures+1, friendlyError(res), nil
		default:
			rt.failures++
			rt.lastErr = friendlyError(res)
			at := time.Now().Add(sched.Backoff(rt.failures)).UTC()
			rt.retryAt = &at
		}
		if rt.pending != nil {
			p := *rt.pending
			rt.pending = nil
			p.RunID = ""
			_, _ = d.triggerLocked(jid, p)
		}
	}
	d.pumpLocked()
	if rt != nil {
		d.publishStateLocked(rt)
	}
	d.publishOverallLocked(true)
	d.mu.Unlock()

	d.applyBandwidth()
	d.reschedule()
}

func friendlyError(res engine.RunResult) string {
	switch res.Fail {
	case engine.FailMaxDelete:
		return "Stopped: too many deletions (safety limit). Review in Action Center."
	case engine.FailAuth:
		return "Sign-in expired: reconnect the account"
	case engine.FailQuota:
		return "Storage is full"
	case engine.FailPermission:
		return "Permission denied"
	case engine.FailNeedsResync:
		return "Two-way state lost: a new baseline is required"
	}
	if res.Err != nil {
		return res.Err.Error()
	}
	return ""
}

// onProgress stores and publishes a progress snapshot.
func (d *Daemon) onProgress(jobID, runID string, p model.Progress) {
	d.mu.Lock()
	rt := d.jobs[jobID]
	if rt == nil || rt.run == nil || rt.run.id != runID {
		d.mu.Unlock()
		return
	}
	rt.progress = &p
	d.publishOverallLocked(false)
	d.mu.Unlock()
	d.srv.PublishLatest("job.progress:"+jobID, "job.progress", map[string]any{"jobId": jobID, "runId": runID, "progress": p})
}

// publishOverallLocked sends overall.progress at most every 250 ms.
func (d *Daemon) publishOverallLocked(force bool) {
	now := time.Now()
	if !force && now.Sub(d.lastOverall) < engine.ProgressInterval {
		return
	}
	d.lastOverall = now
	o := model.OverallProgress{}
	for _, rt := range d.jobs {
		if rt.run == nil || rt.progress == nil {
			continue
		}
		o.Running++
		o.Bytes += rt.progress.Bytes
		o.TotalBytes += rt.progress.TotalBytes
		o.Speed += rt.progress.Speed
	}
	if o.TotalBytes > 0 {
		o.Percent = min(100, float64(o.Bytes)*100/float64(o.TotalBytes))
	}
	if o.Speed > 0 && o.TotalBytes > o.Bytes {
		eta := float64(o.TotalBytes-o.Bytes) / o.Speed
		o.ETA = &eta
	}
	d.srv.PublishLatest("overall.progress", "overall.progress", o)
}

func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}
