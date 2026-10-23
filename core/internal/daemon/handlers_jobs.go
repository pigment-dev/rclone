package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

func (d *Daemon) accountExists(id string) bool {
	_, ok := d.cfg.Account(id)
	return ok
}

func invalid(err error) error { return &api.Error{Code: api.CodeInvalidParams, Message: err.Error()} }

func (d *Daemon) registerJobHandlers() {
	method(d, "jobs.list", func(context.Context, *api.Conn, struct{}) (any, error) {
		out := []model.Job{}
		for _, j := range d.cfg.Jobs() {
			out = append(out, d.jobView(j))
		}
		return map[string]any{"jobs": out}, nil
	})
	method(d, "jobs.get", func(_ context.Context, _ *api.Conn, p idParam) (any, error) {
		j, ok := d.cfg.Job(p.ID)
		if !ok {
			return nil, notFound("job", p.ID)
		}
		return map[string]any{"job": d.jobView(j)}, nil
	})
	method(d, "jobs.create", func(_ context.Context, _ *api.Conn, p struct {
		Job json.RawMessage `json:"job"`
	}) (any, error) {
		j, err := d.CreateJob(p.Job)
		if err != nil {
			return nil, err
		}
		return map[string]any{"job": d.jobView(j)}, nil
	})
	method(d, "jobs.update", func(_ context.Context, _ *api.Conn, p struct {
		ID    string          `json:"id"`
		Patch json.RawMessage `json:"patch"`
	}) (any, error) {
		j, err := d.updateJob(p.ID, p.Patch)
		if err != nil {
			return nil, err
		}
		return map[string]any{"job": d.jobView(j)}, nil
	})
	method(d, "jobs.delete", func(_ context.Context, _ *api.Conn, p idParam) (any, error) {
		if _, ok := d.cfg.Job(p.ID); !ok {
			return nil, notFound("job", p.ID)
		}
		d.deleteJob(p.ID)
		return api.OK, nil
	})
	method(d, "jobs.run", func(_ context.Context, _ *api.Conn, p struct {
		ID     string `json:"id"`
		DryRun bool   `json:"dryRun"`
		Resync bool   `json:"resync"`
	}) (any, error) {
		reason := "started manually"
		if p.Resync {
			reason = "baseline requested"
		}
		id, err := d.TriggerRun(p.ID, runReq{Manual: true, DryRun: p.DryRun, Resync: p.Resync, Reason: reason})
		if err != nil {
			return nil, err
		}
		return map[string]any{"runId": id}, nil
	})
	method(d, "jobs.preview", func(ctx context.Context, _ *api.Conn, p struct {
		ID  string          `json:"id"`
		Job json.RawMessage `json:"job"`
	}) (any, error) {
		return d.preview(ctx, p.ID, p.Job)
	})
	method(d, "jobs.pause", func(_ context.Context, _ *api.Conn, p idParam) (any, error) {
		return d.setPaused(p.ID, true)
	})
	method(d, "jobs.resume", func(_ context.Context, _ *api.Conn, p idParam) (any, error) {
		return d.setPaused(p.ID, false)
	})
	method(d, "jobs.cancel", func(_ context.Context, _ *api.Conn, p idParam) (any, error) {
		d.mu.Lock()
		defer d.mu.Unlock()
		rt := d.jobs[p.ID]
		if rt == nil {
			return nil, notFound("job", p.ID)
		}
		rt.pending, rt.waiting = nil, nil
		if rt.queued != nil {
			rt.queued = nil
			d.publishStateLocked(rt)
		}
		if rt.run != nil {
			rt.run.cancel()
		}
		return api.OK, nil
	})
	method(d, "jobs.pauseAll", func(_ context.Context, _ *api.Conn, p struct {
		UntilSec *int `json:"untilSec"`
	}) (any, error) {
		d.pauseAll(p.UntilSec)
		return api.OK, nil
	})
	method(d, "jobs.resumeAll", func(context.Context, *api.Conn, struct{}) (any, error) {
		d.resumeAll()
		return api.OK, nil
	})
	method(d, "jobs.explain", func(_ context.Context, _ *api.Conn, p struct {
		ID   string `json:"id"`
		Path string `json:"path"`
	}) (any, error) {
		j, ok := d.cfg.Job(p.ID)
		if !ok {
			return nil, notFound("job", p.ID)
		}
		c, err := filters.Compile(j.Filters, filters.Options{LocalRoot: j.LocalPath})
		if err != nil {
			return nil, invalid(err)
		}
		rel := p.Path
		if filepath.IsAbs(rel) {
			r, err := filepath.Rel(j.LocalPath, rel)
			if err != nil || strings.HasPrefix(r, "..") {
				return nil, api.Errorf(api.CodeInvalidParams, "path is outside the job folder")
			}
			rel = r
		}
		inc, rule := c.Explain(j.LocalPath, rel)
		return map[string]any{"included": inc, "rule": rule}, nil
	})
	method(d, "jobs.history", func(ctx context.Context, _ *api.Conn, p struct {
		ID    string `json:"id"`
		Limit int    `json:"limit"`
	}) (any, error) {
		runs, err := d.db.Runs(ctx, p.ID, p.Limit)
		if err != nil {
			return nil, err
		}
		return map[string]any{"runs": runs}, nil
	})
}

// CreateJob validates and stores a new job from a (partial) JSON payload.
func (d *Daemon) CreateJob(raw json.RawMessage) (model.Job, error) {
	st := d.cfg.Settings()
	j := config.NewJobDefaults(st)
	if len(raw) == 0 {
		return j, api.Errorf(api.CodeInvalidParams, "job is required")
	}
	if err := config.MergePatch(&j, raw); err != nil {
		return j, invalid(err)
	}
	config.Normalize(&j, st)
	j.ID = accounts.NewID("job")
	now := time.Now().UTC()
	j.CreatedAt, j.UpdatedAt, j.Status = now, now, nil
	j.LocalPath = filepath.Clean(j.LocalPath)
	if err := config.Validate(&j, d.accountExists); err != nil {
		return j, invalid(err)
	}
	if err := d.cfg.PutJob(j); err != nil {
		return j, err
	}
	_ = d.cfg.UpdateRuntime(j.ID, func(r *config.JobRuntime) {
		r.NeedsBaseline = j.Direction == model.DirTwoWay
	})
	d.mu.Lock()
	d.jobs[j.ID] = d.newRT(j)
	d.refreshWatchLocked(j.ID)
	d.publishStateLocked(d.jobs[j.ID])
	d.mu.Unlock()
	jid := j.ID
	d.logf("notice", &jid, nil, "Job %q created (%s, %s → %s)", j.Name, j.Direction, j.LocalPath, j.RemotePath)
	d.reschedule()
	return j, nil
}

func (d *Daemon) updateJob(id string, patch json.RawMessage) (model.Job, error) {
	old, ok := d.cfg.Job(id)
	if !ok {
		return old, notFound("job", id)
	}
	j := old
	if err := config.MergePatch(&j, patch); err != nil {
		return old, invalid(err)
	}
	config.Normalize(&j, d.cfg.Settings())
	j.ID, j.CreatedAt, j.Status, j.UpdatedAt = old.ID, old.CreatedAt, nil, time.Now().UTC()
	if err := config.Validate(&j, d.accountExists); err != nil {
		return old, invalid(err)
	}
	if err := d.cfg.PutJob(j); err != nil {
		return old, err
	}
	pairChanged := j.LocalPath != old.LocalPath || j.RemotePath != old.RemotePath || j.AccountID != old.AccountID || j.Direction != old.Direction
	if j.Direction == model.DirTwoWay && pairChanged {
		_ = d.cfg.UpdateRuntime(id, func(r *config.JobRuntime) { r.NeedsBaseline = true })
	}
	d.mu.Lock()
	d.refreshWatchLocked(id)
	if rt := d.jobs[id]; rt != nil {
		d.publishStateLocked(rt)
	}
	d.mu.Unlock()
	d.applyBandwidth()
	d.reschedule()
	return j, nil
}

func (d *Daemon) deleteJob(id string) {
	d.mu.Lock()
	if rt := d.jobs[id]; rt != nil {
		if rt.run != nil {
			rt.run.cancel()
		}
		delete(d.jobs, id)
	}
	d.watcher.Remove(id)
	d.mu.Unlock()
	_ = d.cfg.DeleteJob(id)
	_ = os.RemoveAll(filepath.Join(d.opt.Paths.DataDir, "bisync", id))
	d.reschedule()
}

func (d *Daemon) preview(ctx context.Context, id string, raw json.RawMessage) (*model.Preview, error) {
	var j model.Job
	if id != "" {
		var ok bool
		if j, ok = d.cfg.Job(id); !ok {
			return nil, notFound("job", id)
		}
	} else {
		st := d.cfg.Settings()
		j = config.NewJobDefaults(st)
		if err := config.MergePatch(&j, raw); err != nil {
			return nil, invalid(err)
		}
		config.Normalize(&j, st)
		j.ID = "preview"
		if err := config.Validate(&j, d.accountExists); err != nil {
			return nil, invalid(err)
		}
	}
	acc, ok := d.cfg.Account(j.AccountID)
	if !ok {
		return nil, notFound("account", j.AccountID)
	}
	c, err := filters.Compile(j.Filters, filters.Options{LocalRoot: j.LocalPath})
	if err != nil {
		return nil, invalid(err)
	}
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	p, err := d.eng.Preview(ctx, engine.RunSpec{RunID: accounts.NewID("prv"), Job: j, Remote: acc.Remote, Filter: c, DryRun: true, Now: time.Now()})
	if err != nil {
		return nil, providerErr(err)
	}
	if id != "" {
		_ = d.cfg.UpdateRuntime(id, func(r *config.JobRuntime) { r.PreviewDone = true })
		d.srv.Publish("job.preview", map[string]any{"jobId": id, "preview": p})
		d.mu.Lock()
		if rt := d.jobs[id]; rt != nil {
			d.publishStateLocked(rt)
		}
		d.mu.Unlock()
	}
	return p, nil
}

func (d *Daemon) setPaused(id string, paused bool) (any, error) {
	if _, ok := d.cfg.Job(id); !ok {
		return nil, notFound("job", id)
	}
	_ = d.cfg.UpdateRuntime(id, func(r *config.JobRuntime) { r.Paused = paused })
	d.mu.Lock()
	if rt := d.jobs[id]; rt != nil {
		if paused {
			rt.queued, rt.pending, rt.waiting = nil, nil, nil
			if rt.run != nil {
				rt.run.cancel()
			}
		}
		d.publishStateLocked(rt)
	}
	d.mu.Unlock()
	d.reschedule()
	return api.OK, nil
}

func (d *Daemon) pauseAll(untilSec *int) {
	d.mu.Lock()
	d.pausedAll = true
	d.pauseAllUntil = nil
	if d.pauseTimer != nil {
		d.pauseTimer.Stop()
		d.pauseTimer = nil
	}
	if untilSec != nil && *untilSec > 0 {
		t := time.Now().Add(time.Duration(*untilSec) * time.Second).UTC()
		d.pauseAllUntil = &t
		d.pauseTimer = time.AfterFunc(time.Until(t), d.resumeAll)
	}
	for _, rt := range d.jobs {
		rt.queued, rt.pending = nil, nil
		if rt.run != nil {
			rt.run.cancel()
		}
	}
	d.queue = nil
	d.publishAllLocked()
	d.mu.Unlock()
	d.logf("notice", nil, nil, "All syncs paused")
}

func (d *Daemon) resumeAll() {
	d.mu.Lock()
	d.pausedAll = false
	d.pauseAllUntil = nil
	if d.pauseTimer != nil {
		d.pauseTimer.Stop()
		d.pauseTimer = nil
	}
	d.publishAllLocked()
	d.mu.Unlock()
	d.logf("notice", nil, nil, "Syncs resumed")
	d.reschedule()
}
