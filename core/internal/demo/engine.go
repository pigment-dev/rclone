// Package demo provides a network-free simulated engine and seed data for
// screenshots and the README GIF (pdrcloned --demo).
package demo

import (
	"context"
	"fmt"
	"math"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/rclone/rclone/fs"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/policy"
)

// Engine simulates syncs with smoothly changing progress.
type Engine struct {
	mu   sync.Mutex
	sink engine.LogFn
	// Finished receives the job id when a simulated run ends.
	Finished chan string
}

// NewEngine returns the simulator.
func NewEngine() *Engine { return &Engine{Finished: make(chan string, 16)} }

var demoFiles = []string{
	"pigment-site/assets/hero-poster.png", "pigment-site/assets/demo.mp4", "rclone-app/docs/media/dashboard-dark.png",
	"client-acme/brand/Acme Brand Book.pdf", "client-acme/exports/landing-v3.fig", "keep-me-up/dist/KeepMeUp.dmg",
	"photos-2026/IMG_4021.HEIC", "photos-2026/IMG_4022.HEIC", "invoices/2026-10/INV-1042.pdf", "hush/Resources/AppIcon.icns",
	"pigment-site/index.html", "rclone-app/core/internal/engine/run.go", "client-acme/video/teaser-4k.mov",
}

// Run simulates a run. The long upload of the "Projects" job drives the
// menu-bar ring; other jobs finish in a few seconds.
func (e *Engine) Run(ctx context.Context, spec engine.RunSpec, progress engine.ProgressFn) engine.RunResult {
	defer func() {
		select {
		case e.Finished <- spec.Job.ID:
		default:
		}
	}()
	total, files := int64(42<<20), int64(12)
	base, swing := 6.0e6, 2.0e6
	if spec.Job.ID == JobProjects {
		total, files, base, swing = 860<<20, 214, 11.5e6, 3.5e6
	}
	if spec.DryRun {
		total, files = 0, 0
	}
	start := time.Now()
	var bytes float64
	tick := time.NewTicker(engine.ProgressInterval)
	defer tick.Stop()
	for int64(bytes) < total {
		select {
		case <-ctx.Done():
			return engine.RunResult{Bytes: int64(bytes), Err: ctx.Err(), Fail: engine.FailCancelled}
		case <-tick.C:
		}
		t := time.Since(start).Seconds()
		speed := base + swing*math.Sin(t/3.2) + 0.6e6*math.Sin(t*1.7)
		bytes = math.Min(float64(total), bytes+speed*engine.ProgressInterval.Seconds())
		done := int64(float64(files) * bytes / float64(total))
		eta := (float64(total) - bytes) / speed
		p := model.Progress{
			Bytes: int64(bytes), TotalBytes: total, Files: done, TotalFiles: files, Speed: speed, ETA: &eta,
			Percent: bytes * 100 / float64(total), Checks: done + 37, TotalChecks: files + 37, Transferring: []model.Transfer{},
		}
		for i := range 3 {
			idx := (int(done) + i) % len(demoFiles)
			size := int64(18<<20 + idx*7<<20)
			frac := math.Mod(t/6+float64(i)*0.31, 1)
			p.Transferring = append(p.Transferring, model.Transfer{Name: demoFiles[idx], Size: size, Bytes: int64(frac * float64(size)), Percent: frac * 100, Speed: speed / 3})
		}
		if progress != nil {
			progress(p)
		}
		if int(t)%9 == 0 && int(t*4)%4 == 0 {
			e.log("info", spec, fmt.Sprintf("Copied (new) to: %s", demoFiles[int(done)%len(demoFiles)]))
		}
	}
	return engine.RunResult{Bytes: total, Files: files}
}

func (e *Engine) log(level string, spec engine.RunSpec, msg string) {
	e.mu.Lock()
	sink := e.sink
	e.mu.Unlock()
	if sink != nil {
		j, r := spec.Job.ID, spec.RunID
		sink(model.LogLine{TS: time.Now().UTC(), Level: level, JobID: &j, RunID: &r, Msg: msg})
	}
}

// Preview returns a canned but plausible preview.
func (e *Engine) Preview(_ context.Context, spec engine.RunSpec) (*model.Preview, error) {
	p := &model.Preview{Adds: 1284, Updates: 37, Deletes: 4, Excluded: 9, Bytes: 3_412_000_000}
	p.Sample.Adds = []string{"pigment-site/index.html", "pigment-site/assets/site.css", "rclone-app/README.md", "client-acme/brand/logo.svg"}
	p.Sample.Updates = []string{"invoices/2026-10/INV-1042.pdf", "rclone-app/core/go.mod"}
	p.Sample.Deletes = []string{"old-drafts/landing-v1.fig", "tmp/export.zip"}
	if spec.Job.DeletePolicy == model.DeleteNever || spec.Job.Direction == model.DirTwoWay {
		p.Deletes, p.Sample.Deletes = 0, []string{}
	}
	p.Sample.Excluded = []model.Excluded{
		{Path: "rclone-app/.git/", Rule: "- .git/** (preset vcs)"},
		{Path: "pigment-site/node_modules/", Rule: "- node_modules/** (preset deps)"},
		{Path: "rclone-app/.claude/", Rule: "- .claude/** (preset ide)"},
		{Path: ".DS_Store", Rule: "- .DS_Store (preset osjunk)"},
		{Path: "hush/.build/", Rule: "- .build/** (preset build)"},
	}
	return p, nil
}

// List returns a small fake tree.
func (e *Engine) List(_ context.Context, remote, p string, dirsOnly bool) ([]model.Entry, error) {
	names := []string{"Backups", "Clients", "Documents", "Photos", "Projects", "Shared with me"}
	if p != "" && p != "/" {
		names = []string{"2024", "2025", "2026", "Archive", "Drafts"}
	}
	out := []model.Entry{}
	now := time.Now().UTC()
	for i, n := range names {
		out = append(out, model.Entry{Name: n, Path: strings.TrimPrefix(path.Join(p, n), "/"), IsDir: true, ModTime: now.Add(-time.Duration(i*37) * time.Hour)})
	}
	if !dirsOnly {
		out = append(out, model.Entry{Name: "README.pdf", Path: strings.TrimPrefix(path.Join(p, "README.pdf"), "/"), Size: 482_113, ModTime: now.Add(-72 * time.Hour)})
	}
	return out, nil
}

// Mkdir pretends to create a folder.
func (e *Engine) Mkdir(context.Context, string, string) error { return nil }

// About returns canned quotas.
func (e *Engine) About(_ context.Context, remote string) (*model.Quota, error) {
	tb := int64(1) << 40
	switch remote {
	case "pd_" + AccWork:
		return &model.Quota{Total: model.Ptr(2 * tb), Used: model.Ptr(tb * 121 / 100), Free: model.Ptr(tb * 79 / 100), Trashed: model.Ptr(int64(3_200_000_000))}, nil
	case "pd_" + AccPersonal:
		return &model.Quota{Total: model.Ptr(2 * tb), Used: model.Ptr(int64(640) << 30), Free: model.Ptr(2*tb - int64(640)<<30)}, nil
	case "pd_" + AccNAS:
		return &model.Quota{Total: model.Ptr(8 * tb), Used: model.Ptr(5 * tb), Free: model.Ptr(3 * tb)}, nil
	}
	return nil, engine.ErrUnsupported
}

// Test always succeeds quickly.
func (e *Engine) Test(context.Context, string) (time.Duration, error) {
	return 124 * time.Millisecond, nil
}

// Identity returns made-up signed-in users for the demo accounts.
func (e *Engine) Identity(_ context.Context, remote string) (*model.Identity, error) {
	switch remote {
	case "pd_" + AccWork:
		return &model.Identity{Name: "Alex Rivera", Email: "alex@studio.example"}, nil
	case "pd_" + AccPersonal:
		return &model.Identity{Name: "Alex Rivera", Email: "alex.rivera@example.com"}, nil
	}
	return nil, engine.ErrUnsupported
}

// DeleteRemote is a no-op.
func (e *Engine) DeleteRemote(string) {}

// SetBandwidth is a no-op.
func (e *Engine) SetBandwidth(policy.Limit) error { return nil }

// ResolveConflict is a no-op.
func (e *Engine) ResolveConflict(context.Context, model.Job, engine.Conflict, string) error {
	return nil
}

// DedupeScan returns a canned duplicate group.
func (e *Engine) DedupeScan(context.Context, string, string) ([]engine.DupGroup, error) {
	t := time.Now().UTC()
	return []engine.DupGroup{{Name: "Clients/Acme/contract.pdf", Files: []engine.DupFile{
		{ID: "1a2b", Path: "Clients/Acme/contract.pdf", Size: 210_442, ModTime: t.Add(-48 * time.Hour)},
		{ID: "3c4d", Path: "Clients/Acme/contract.pdf", Size: 210_442, ModTime: t.Add(-47 * time.Hour)},
	}}}, nil
}

// DedupeApply pretends to remove duplicates.
func (e *Engine) DedupeApply(context.Context, string, string, string) (int, int, error) {
	return 1, 0, nil
}

// RcloneVersion reports the embedded rclone version.
func (e *Engine) RcloneVersion() string { return fs.VersionTag }

// SetLogSink sets the log destination.
func (e *Engine) SetLogSink(fn engine.LogFn) {
	e.mu.Lock()
	e.sink = fn
	e.mu.Unlock()
}

// Flow fakes account creation without network access.
type Flow struct {
	mu       sync.Mutex
	sessions map[string]accounts.Result
}

// NewFlow returns a fake account flow.
func NewFlow() *Flow { return &Flow{sessions: map[string]accounts.Result{}} }

// Start returns needsOAuth for OAuth providers, else done.
func (f *Flow) Start(_ context.Context, accountID, provider, name string, _ map[string]any) (*accounts.Result, error) {
	acc := &model.Account{ID: accountID, Provider: provider, Name: name, Remote: "pd_" + accountID, Status: model.AccountOK, CreatedAt: time.Now().UTC()}
	if !accounts.IsOAuth(provider) {
		return &accounts.Result{State: "done", Account: acc}, nil
	}
	id := "ses_" + accounts.RandID(8)
	f.mu.Lock()
	f.sessions[id] = accounts.Result{State: "done", Account: acc}
	f.mu.Unlock()
	return &accounts.Result{State: "needsOAuth", SessionID: id, AuthURL: "http://127.0.0.1:53682/auth?state=demo"}, nil
}

// Continue completes the fake OAuth.
func (f *Flow) Continue(_ context.Context, id string, _ any) (*accounts.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.sessions[id]
	if !ok {
		return nil, accounts.ErrSessionNotFound
	}
	delete(f.sessions, id)
	return &r, nil
}

// Cancel drops a session.
func (f *Flow) Cancel(id string) error {
	f.mu.Lock()
	delete(f.sessions, id)
	f.mu.Unlock()
	return nil
}

// Reconnect pretends the sign-in was renewed.
func (f *Flow) Reconnect(_ context.Context, acc model.Account) (*accounts.Result, error) {
	id := "ses_" + accounts.RandID(8)
	acc.Status, acc.Error = model.AccountOK, nil
	f.mu.Lock()
	f.sessions[id] = accounts.Result{State: "done", Account: &acc}
	f.mu.Unlock()
	return &accounts.Result{State: "needsOAuth", SessionID: id, AuthURL: "http://127.0.0.1:53682/auth?state=demo"}, nil
}
