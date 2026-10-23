package engine

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/config/configfile"
	"github.com/rclone/rclone/fs/rc"

	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/policy"
)

// Options configure the embedded rclone.
type Options struct {
	ConfigPath string // encrypted rclone.conf
	Passphrase string // rclone.conf encryption passphrase ("" = unencrypted)
	LogLevel   string // debug|info|notice
	TPSLimit   int
}

// Rclone is the in-process rclone engine.
type Rclone struct {
	mu     sync.Mutex
	sink   LogFn
	active map[string]*activeRun // runID → run, for log attribution
}

type activeRun struct {
	jobID, runID string
	observe      func(msg string)
}

// NewRclone initialises rclone's global state. Call once per process.
func NewRclone(opt Options) (*Rclone, error) {
	r := &Rclone{active: map[string]*activeRun{}}
	if err := config.SetConfigPath(opt.ConfigPath); err != nil {
		return nil, err
	}
	if opt.Passphrase != "" {
		if err := config.SetConfigPassword(opt.Passphrase); err != nil {
			return nil, err
		}
	}
	configfile.Install()
	ci := fs.GetConfig(context.Background())
	ci.LogLevel = parseLevel(opt.LogLevel)
	ci.AskPassword = false
	ci.UseServerModTime = false
	if opt.TPSLimit > 0 {
		ci.TPSLimit = float64(opt.TPSLimit)
	}
	fs.SetLogger(&logHandler{r: r})
	accounting.Start(context.Background())
	// Load (and if needed create) the config so errors surface at start.
	_ = config.LoadedData()
	return r, nil
}

// SetLogLevel changes rclone's verbosity at runtime.
func SetLogLevel(level string) {
	fs.GetConfig(context.Background()).LogLevel = parseLevel(level)
}

func parseLevel(l string) fs.LogLevel {
	switch l {
	case "debug":
		return fs.LogLevelDebug
	case "notice", "warn", "error":
		return fs.LogLevelNotice
	}
	return fs.LogLevelInfo
}

// SetLogSink sets where rclone log lines go.
func (r *Rclone) SetLogSink(fn LogFn) {
	r.mu.Lock()
	r.sink = fn
	r.mu.Unlock()
}

// RcloneVersion returns the embedded rclone version.
func (r *Rclone) RcloneVersion() string { return fs.VersionTag }

func (r *Rclone) register(jobID, runID string, observe func(string)) func() {
	r.mu.Lock()
	r.active[runID] = &activeRun{jobID: jobID, runID: runID, observe: observe}
	r.mu.Unlock()
	return func() {
		r.mu.Lock()
		delete(r.active, runID)
		r.mu.Unlock()
	}
}

// SetBandwidth applies a process-wide bandwidth limit.
func (r *Rclone) SetBandwidth(l policy.Limit) error {
	call := rc.Calls.Get("core/bwlimit")
	if call == nil {
		return fmt.Errorf("core/bwlimit not registered")
	}
	_, err := call.Fn(context.Background(), rc.Params{"rate": l.String()})
	return err
}

// DeleteRemote removes a remote from rclone.conf.
func (r *Rclone) DeleteRemote(remote string) {
	config.DeleteRemote(remote)
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// logHandler adapts rclone's slog output to LogLines.
type logHandler struct {
	r     *Rclone
	attrs []slog.Attr
}

func (h *logHandler) Enabled(_ context.Context, l slog.Level) bool { return true }

func (h *logHandler) WithAttrs(as []slog.Attr) slog.Handler {
	return &logHandler{r: h.r, attrs: append(append([]slog.Attr(nil), h.attrs...), as...)}
}

func (h *logHandler) WithGroup(string) slog.Handler { return h }

func (h *logHandler) Handle(_ context.Context, rec slog.Record) error {
	msg := strings.TrimSpace(ansi.ReplaceAllString(rec.Message, ""))
	if msg == "" {
		return nil
	}
	var object string
	rec.Attrs(func(a slog.Attr) bool {
		if a.Key == "object" {
			object = a.Value.String()
			return false
		}
		return true
	})
	line := model.LogLine{TS: rec.Time.UTC(), Level: slogLevelName(rec.Level), Msg: msg}
	if line.TS.IsZero() {
		line.TS = time.Now().UTC()
	}
	if object != "" && !strings.HasPrefix(object, "*") {
		line.Path = &object
	}
	h.r.mu.Lock()
	sink := h.r.sink
	var observers []func(string)
	for _, a := range h.r.active {
		if a.observe != nil {
			observers = append(observers, a.observe)
		}
	}
	// Attribute to the run only when unambiguous.
	if len(h.r.active) == 1 {
		for _, a := range h.r.active {
			j, ru := a.jobID, a.runID
			line.JobID, line.RunID = &j, &ru
		}
	}
	h.r.mu.Unlock()
	for _, o := range observers {
		o(msg)
	}
	if sink != nil {
		sink(line)
	}
	return nil
}

func slogLevelName(l slog.Level) string {
	switch {
	case l >= slog.LevelError:
		return "error"
	case l >= slog.LevelWarn:
		return "warn"
	case l >= slog.LevelInfo+2:
		return "notice"
	case l >= slog.LevelInfo:
		return "info"
	}
	return "debug"
}
