package daemon

import (
	"time"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/policy"
	"github.com/pigment-dev/rclone/core/internal/sched"
	"github.com/pigment-dev/rclone/core/internal/watch"
)

// ReconcileEvery is the periodic full run for on-change upload jobs whose
// quick syncs only copy changed paths.
var ReconcileEvery = 6 * time.Hour

// maxTimer caps the scheduler sleep so wall-clock jumps (sleep, clock
// changes) are noticed even without a wake notification.
const maxTimer = time.Hour

// nextDueLocked computes when a job should next run automatically.
func (d *Daemon) nextDueLocked(rt *jobRT, j model.Job) (*time.Time, string) {
	r := d.cfg.Runtime(j.ID)
	if !j.Enabled || r.Paused || d.pausedAll {
		return nil, ""
	}
	var best *time.Time
	why := ""
	consider := func(t *time.Time, reason string) {
		if t != nil && (best == nil || t.Before(*best)) {
			best, why = t, reason
		}
	}
	anchor := j.CreatedAt
	if rt.lastRun != nil && !rt.lastRun.DryRun {
		anchor = rt.lastRun.StartedAt
	}
	consider(sched.Next(j.Triggers, anchor, time.Now()), "schedule")
	if j.Triggers.OnChange && j.Direction == model.DirUpload {
		last := j.CreatedAt
		if t, err := time.Parse(time.RFC3339, r.LastFullReconcile); err == nil {
			last = t
		}
		next := last.Add(ReconcileEvery).UTC()
		consider(&next, "periodic full reconcile")
	}
	consider(rt.retryAt, "retry after error")
	return best, why
}

// reschedule recomputes next runs, fires due ones and re-arms the timer.
func (d *Daemon) reschedule() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.ctx.Err() != nil {
		return
	}
	now := time.Now()
	var earliest *time.Time
	for _, rt := range d.jobs {
		j, ok := d.cfg.Job(rt.id)
		if !ok {
			continue
		}
		next, why := d.nextDueLocked(rt, j)
		if d.opt.Demo && next != nil && !next.After(now) {
			// Demo mode never fires schedules; show the next future slot.
			next = sched.Next(j.Triggers, now, now)
		}
		rt.nextRun = next
		if next != nil && !next.After(now) && rt.run == nil && rt.queued == nil && rt.waiting == nil {
			rt.retryAt = nil
			req := runReq{Reason: why}
			if r := d.cfg.Runtime(j.ID); j.Direction == model.DirTwoWay && r.NeedsBaseline {
				continue
			}
			_, _ = d.triggerLocked(rt.id, req)
			// Re-evaluate after the run; don't fire again in a loop.
			if rt.run == nil && rt.queued == nil {
				// Blocked (policy, preview-first): look again later.
				later := now.Add(maxTimer)
				next = &later
			} else {
				continue
			}
		}
		if next != nil && (earliest == nil || next.Before(*earliest)) {
			earliest = next
		}
		d.publishStateLocked(rt)
	}
	wait := maxTimer
	if earliest != nil {
		wait = min(maxTimer, max(time.Second, time.Until(*earliest)))
	}
	if d.schedTimer == nil {
		d.schedTimer = time.AfterFunc(wait, d.reschedule)
	} else {
		d.schedTimer.Reset(wait)
	}
}

// refreshWatchLocked (re)configures the file watcher for a job.
func (d *Daemon) refreshWatchLocked(id string) {
	j, ok := d.cfg.Job(id)
	if !ok || d.opt.Demo || !j.Enabled || !j.Triggers.OnChange || j.Direction == model.DirDownload {
		d.watcher.Remove(id)
		return
	}
	c, err := filters.Compile(j.Filters, filters.Options{LocalRoot: j.LocalPath})
	if err != nil {
		d.watcher.Remove(id)
		return
	}
	if err := d.watcher.Set(watch.Job{ID: id, Root: j.LocalPath, Filter: c, Debounce: time.Duration(j.Triggers.DebounceSec) * time.Second}); err != nil {
		jid := id
		d.logf("warn", &jid, nil, "Cannot watch %s for changes: %v", j.LocalPath, err)
	}
}

// onChange is called by the watcher after the debounce window.
func (d *Daemon) onChange(id string, c watch.Change) {
	j, ok := d.cfg.Job(id)
	if !ok {
		return
	}
	req := runReq{Reason: "files changed"}
	if j.Direction == model.DirUpload && !c.Overflow && !(c.Removed && j.DeletePolicy != model.DeleteNever) && len(c.Paths) > 0 {
		req.Files = c.Paths
	}
	if j.Direction == model.DirUpload && len(c.Paths) == 0 && c.Removed && j.DeletePolicy == model.DeleteNever {
		return // deletions are never propagated for this job
	}
	_, _ = d.TriggerRun(id, req)
}

// setSystemState stores a system.state push and re-evaluates policy.
func (d *Daemon) setSystemState(st model.SystemState) {
	d.mu.Lock()
	woke := d.sys != nil && d.sys.Sleeping && !st.Sleeping
	d.sys = &st
	settings := d.cfg.Settings()
	for _, rt := range d.jobs {
		j, ok := d.cfg.Job(rt.id)
		if !ok {
			continue
		}
		why, allowed := policy.Evaluate(j, settings, d.sys)
		switch {
		case !allowed && rt.run != nil && !rt.run.blocked:
			jid := rt.id
			d.logf("notice", &jid, &rt.run.id, "Pausing %q: %s", j.Name, why)
			rt.run.blocked = true
			rt.run.cancel()
		case allowed && rt.waiting != nil:
			req := *rt.waiting
			rt.waiting = nil
			req.RunID = ""
			_, _ = d.triggerLocked(rt.id, req)
		}
		if woke && j.Triggers.OnWake {
			_, _ = d.triggerLocked(rt.id, runReq{Reason: "computer woke up"})
		}
	}
	d.publishAllLocked()
	d.mu.Unlock()
	if woke {
		d.reschedule() // missed-run catch-up
	}
}

// applyBandwidth pushes the effective global limit to rclone and arms a
// timer for the next timetable boundary.
func (d *Daemon) applyBandwidth() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.ctx.Err() != nil {
		return
	}
	s := d.cfg.Settings()
	var running []model.Job
	for _, rt := range d.jobs {
		if rt.run != nil {
			if j, ok := d.cfg.Job(rt.id); ok {
				running = append(running, j)
			}
		}
	}
	l := policy.Bandwidth(s, time.Now(), running)
	if l.String() != d.lastBw {
		if err := d.eng.SetBandwidth(l); err == nil {
			d.lastBw = l.String()
		}
	}
	if d.bwTimer != nil {
		d.bwTimer.Stop()
		d.bwTimer = nil
	}
	if next := policy.NextBoundary(s.Network.BwSchedule, time.Now()); next != nil {
		d.bwTimer = time.AfterFunc(time.Until(*next)+time.Second, d.applyBandwidth)
	}
}

// SetSystemState applies a system state (demo mode and tests).
func (d *Daemon) SetSystemState(st model.SystemState) { d.setSystemState(st) }

// RunNow starts a manual run (demo loop, CLI helpers).
func (d *Daemon) RunNow(jobID, reason string) (string, error) {
	return d.TriggerRun(jobID, runReq{Manual: true, Reason: reason})
}
