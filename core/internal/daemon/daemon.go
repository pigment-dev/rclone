// Package daemon wires config, store, engine, scheduler, watcher, policy
// and the JSON-RPC API together.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/ipc"
	"github.com/pigment-dev/rclone/core/internal/keyring"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/paths"
	"github.com/pigment-dev/rclone/core/internal/platform"
	"github.com/pigment-dev/rclone/core/internal/store"
	"github.com/pigment-dev/rclone/core/internal/watch"
)

// MaxConcurrentRuns limits simultaneous runs across jobs.
var MaxConcurrentRuns = 2

// Options configure a daemon.
type Options struct {
	Paths    paths.Paths
	LogLevel string // overrides settings when set
	Demo     bool
	// Engine and Flow override the real rclone implementations (demo, tests).
	Engine engine.Engine
	Flow   accounts.Flow
	// SelfDetect enables best-effort system state detection (Linux/Windows).
	SelfDetect bool
	// Stderr mirrors log lines to stderr when set.
	Stderr bool
}

// Daemon is the running service.
type Daemon struct {
	opt       Options
	cfg       *config.Store
	db        *store.Store
	eng       engine.Engine
	flow      accounts.Flow
	srv       *api.Server
	watcher   *watch.Watcher
	startedAt time.Time

	mu            sync.Mutex
	jobs          map[string]*jobRT
	queue         []string
	running       int
	sys           *model.SystemState
	pausedAll     bool
	pauseAllUntil *time.Time
	pauseTimer    *time.Timer
	schedTimer    *time.Timer
	bwTimer       *time.Timer
	lastOverall   time.Time
	lastBw        string
	lastHealth    string

	listener net.Listener
	done     chan struct{}
	stopOnce sync.Once
	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

// New opens config and the store and initialises the engine.
func New(opt Options) (*Daemon, error) {
	if err := opt.Paths.Ensure(); err != nil {
		return nil, err
	}
	cfg, err := config.Open(opt.Paths.ConfigDir)
	if err != nil {
		return nil, err
	}
	db, err := store.Open(opt.Paths.DataDir)
	if err != nil {
		return nil, err
	}
	d := &Daemon{opt: opt, cfg: cfg, db: db, jobs: map[string]*jobRT{}, startedAt: time.Now().UTC(), done: make(chan struct{})}
	d.ctx, d.cancel = context.WithCancel(context.Background())
	st := cfg.Settings()
	level := st.Logs.Level
	if opt.LogLevel != "" {
		level = opt.LogLevel
	}
	if opt.Engine != nil {
		d.eng = opt.Engine
	} else {
		ks := keyring.Source{Dir: opt.Paths.ConfigDir, FileFallback: opt.Paths.Override || opt.Demo}
		pass, where, err := ks.Passphrase()
		if err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("config passphrase: %w", err)
		}
		r, err := engine.NewRclone(engine.Options{
			ConfigPath: filepath.Join(opt.Paths.ConfigDir, "rclone.conf"),
			Passphrase: pass,
			LogLevel:   level,
			TPSLimit:   st.Engine.TPSLimit,
		})
		if err != nil {
			_ = db.Close()
			return nil, err
		}
		d.eng = r
		defer d.logf("info", nil, nil, "rclone.conf passphrase from %s", where)
	}
	if opt.Flow != nil {
		d.flow = opt.Flow
	} else {
		d.flow = accounts.NewRcloneFlow()
	}
	d.eng.SetLogSink(d.addLog)
	d.watcher = watch.New(d.onChange)
	d.srv = api.NewServer()
	d.registerHandlers()
	for _, j := range cfg.Jobs() {
		d.jobs[j.ID] = d.newRT(j)
	}
	return d, nil
}

// Server exposes the RPC server (tests).
func (d *Daemon) Server() *api.Server { return d.srv }

// Config exposes the config store (demo seeding).
func (d *Daemon) Config() *config.Store { return d.cfg }

// DB exposes the history store (demo seeding).
func (d *Daemon) DB() *store.Store { return d.db }

// Start begins listening and scheduling.
func (d *Daemon) Start() error {
	l, err := ipc.Listen(d.opt.Paths.Socket)
	if err != nil {
		return err
	}
	d.listener = l
	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		if err := d.srv.Serve(l); err != nil {
			d.logf("error", nil, nil, "rpc server: %v", err)
		}
	}()
	d.logf("notice", nil, nil, "pdrcloned started (pid %d, %s/%s, socket %s)", os.Getpid(), runtime.GOOS, runtime.GOARCH, d.opt.Paths.Socket)
	d.mu.Lock()
	for id := range d.jobs {
		d.refreshWatchLocked(id)
	}
	d.mu.Unlock()
	d.applyBandwidth()
	d.reschedule()
	if d.opt.SelfDetect {
		d.wg.Add(1)
		go func() {
			defer d.wg.Done()
			platform.WatchSystemState(d.ctx, func(st model.SystemState) { d.setSystemState(st) })
		}()
	}
	d.wg.Add(1)
	go d.maintenance()
	return nil
}

// Done is closed after Stop.
func (d *Daemon) Done() <-chan struct{} { return d.done }

// Stop cancels runs, closes the socket and flushes the store.
func (d *Daemon) Stop() {
	d.stopOnce.Do(func() {
		d.logf("notice", nil, nil, "pdrcloned stopping")
		d.cancel()
		d.mu.Lock()
		for _, rt := range d.jobs {
			if rt.run != nil {
				rt.run.cancel()
			}
		}
		for _, t := range []*time.Timer{d.schedTimer, d.bwTimer, d.pauseTimer} {
			if t != nil {
				t.Stop()
			}
		}
		d.mu.Unlock()
		if d.listener != nil {
			_ = d.listener.Close()
		}
		d.srv.Close()
		d.watcher.Close()
		ipc.Cleanup(d.opt.Paths.Socket)
		d.waitRuns(10 * time.Second)
		d.wg.Wait()
		_ = d.db.Close()
		close(d.done)
	})
}

func (d *Daemon) waitRuns(timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		n := d.running
		d.mu.Unlock()
		if n == 0 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// maintenance prunes old history once a day.
func (d *Daemon) maintenance() {
	defer d.wg.Done()
	t := time.NewTimer(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			days := d.cfg.Settings().Logs.RetentionDays
			if days <= 0 {
				days = 30
			}
			if err := d.db.Prune(d.ctx, time.Duration(days)*24*time.Hour); err != nil && !errors.Is(err, context.Canceled) {
				d.logf("warn", nil, nil, "prune history: %v", err)
			}
			t.Reset(24 * time.Hour)
		}
	}
}

// addLog stores and publishes a log line.
func (d *Daemon) addLog(l model.LogLine) {
	l = d.db.AddLog(l)
	if d.opt.Stderr {
		fmt.Fprintf(os.Stderr, "%s %-6s %s\n", l.TS.Local().Format("15:04:05"), l.Level, l.Msg)
	}
	d.srv.Publish("log.line", map[string]any{"line": l})
}

func (d *Daemon) logf(level string, jobID, runID *string, format string, args ...any) {
	d.addLog(model.LogLine{TS: time.Now().UTC(), Level: level, JobID: jobID, RunID: runID, Msg: fmt.Sprintf(format, args...)})
}

func (d *Daemon) health(ok bool, msg string) {
	d.mu.Lock()
	key := fmt.Sprint(ok, msg)
	if key == d.lastHealth {
		d.mu.Unlock()
		return
	}
	d.lastHealth = key
	d.mu.Unlock()
	d.srv.Publish("daemon.health", map[string]any{"ok": ok, "message": msg})
}
