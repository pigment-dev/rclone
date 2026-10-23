package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"

	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/diag"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/store"
	"github.com/pigment-dev/rclone/core/internal/version"
)

func (d *Daemon) remoteFor(accountID *string) (string, error) {
	if accountID == nil || *accountID == "" {
		return "", nil
	}
	acc, ok := d.cfg.Account(*accountID)
	if !ok {
		return "", notFound("account", *accountID)
	}
	return acc.Remote, nil
}

func (d *Daemon) registerMiscHandlers() {
	method(d, "remote.list", func(ctx context.Context, _ *api.Conn, p struct {
		AccountID *string `json:"accountId"`
		Path      string  `json:"path"`
		DirsOnly  *bool   `json:"dirsOnly"`
	}) (any, error) {
		remote, err := d.remoteFor(p.AccountID)
		if err != nil {
			return nil, err
		}
		dirsOnly := p.DirsOnly == nil || *p.DirsOnly
		if remote == "" && p.Path == "" {
			p.Path, _ = os.UserHomeDir()
		}
		entries, err := d.eng.List(ctx, remote, p.Path, dirsOnly)
		if err != nil {
			return nil, providerErr(err)
		}
		return map[string]any{"path": p.Path, "entries": entries}, nil
	})
	method(d, "remote.mkdir", func(ctx context.Context, _ *api.Conn, p struct {
		AccountID *string `json:"accountId"`
		Path      string  `json:"path"`
	}) (any, error) {
		remote, err := d.remoteFor(p.AccountID)
		if err != nil {
			return nil, err
		}
		if err := d.eng.Mkdir(ctx, remote, p.Path); err != nil {
			return nil, providerErr(err)
		}
		return api.OK, nil
	})
	method(d, "actions.list", func(ctx context.Context, _ *api.Conn, p struct {
		IncludeResolved bool `json:"includeResolved"`
	}) (any, error) {
		as, err := d.db.Actions(ctx, p.IncludeResolved)
		if err != nil {
			return nil, err
		}
		return map[string]any{"actions": as}, nil
	})
	method(d, "actions.resolve", func(ctx context.Context, _ *api.Conn, p struct {
		ID     string `json:"id"`
		Choice string `json:"choice"`
	}) (any, error) {
		a, err := d.ResolveAction(ctx, p.ID, p.Choice)
		if err != nil {
			return nil, err
		}
		return map[string]any{"action": a}, nil
	})
	method(d, "actions.dismissAll", func(ctx context.Context, _ *api.Conn, _ struct{}) (any, error) {
		as, err := d.db.Actions(ctx, false)
		if err != nil {
			return nil, err
		}
		for _, a := range as {
			_, _ = d.ResolveAction(ctx, a.ID, "dismiss")
		}
		return map[string]any{"ok": true, "count": len(as)}, nil
	})
	method(d, "log.query", func(ctx context.Context, _ *api.Conn, q store.LogQuery) (any, error) {
		lines, err := d.db.QueryLogs(ctx, q)
		if err != nil {
			return nil, err
		}
		return map[string]any{"lines": lines}, nil
	})
	method(d, "log.export", func(ctx context.Context, _ *api.Conn, p struct {
		JobID  string `json:"jobId"`
		Format string `json:"format"`
		Dest   string `json:"dest"`
	}) (any, error) {
		if !filepath.IsAbs(p.Dest) {
			return nil, api.Errorf(api.CodeInvalidParams, "dest must be an absolute path")
		}
		lines, err := d.db.QueryLogs(ctx, store.LogQuery{JobID: p.JobID, Limit: 5000})
		if err != nil {
			return nil, err
		}
		slices.Reverse(lines)
		if err := diag.WriteLogs(p.Dest, p.Format, lines); err != nil {
			return nil, err
		}
		return map[string]any{"path": p.Dest}, nil
	})
	method(d, "diag.bundle", func(ctx context.Context, _ *api.Conn, p struct {
		Dest string `json:"dest"`
	}) (any, error) {
		if !filepath.IsAbs(p.Dest) {
			return nil, api.Errorf(api.CodeInvalidParams, "dest must be an absolute path")
		}
		lines, _ := d.db.QueryLogs(ctx, store.LogQuery{Limit: 2000})
		slices.Reverse(lines)
		as, _ := d.db.Actions(ctx, true)
		err := diag.Bundle(p.Dest, diag.Input{
			Info: d.helloInfo(), Settings: d.cfg.Settings(), Jobs: d.cfg.Jobs(), Accounts: d.cfg.Accounts(),
			Actions: as, Logs: lines,
		})
		if err != nil {
			return nil, err
		}
		return map[string]any{"path": p.Dest}, nil
	})
	method(d, "settings.get", func(context.Context, *api.Conn, struct{}) (any, error) {
		return map[string]any{"settings": d.cfg.Settings()}, nil
	})
	method(d, "settings.set", func(_ context.Context, _ *api.Conn, p struct {
		Patch json.RawMessage `json:"patch"`
	}) (any, error) {
		st, err := d.SetSettings(p.Patch)
		if err != nil {
			return nil, err
		}
		return map[string]any{"settings": st}, nil
	})
	method(d, "tools.dedupe.scan", func(ctx context.Context, _ *api.Conn, p struct {
		AccountID string `json:"accountId"`
		Path      string `json:"path"`
	}) (any, error) {
		remote, err := d.remoteFor(&p.AccountID)
		if err != nil || remote == "" {
			return nil, notFound("account", p.AccountID)
		}
		groups, err := d.eng.DedupeScan(ctx, remote, p.Path)
		if err != nil {
			return nil, providerErr(err)
		}
		return map[string]any{"groups": groups}, nil
	})
	method(d, "tools.dedupe.apply", func(ctx context.Context, _ *api.Conn, p struct {
		AccountID string `json:"accountId"`
		Path      string `json:"path"`
		Mode      string `json:"mode"`
	}) (any, error) {
		remote, err := d.remoteFor(&p.AccountID)
		if err != nil || remote == "" {
			return nil, notFound("account", p.AccountID)
		}
		removed, renamed, err := d.eng.DedupeApply(ctx, remote, p.Path, p.Mode)
		if err != nil {
			return nil, providerErr(err)
		}
		return map[string]any{"removed": removed, "renamed": renamed}, nil
	})
	method(d, "config.export", func(context.Context, *api.Conn, struct{}) (any, error) {
		return d.exportConfig(), nil
	})
	method(d, "config.import", func(_ context.Context, _ *api.Conn, p ConfigBundle) (any, error) {
		return d.importConfig(p)
	})
}

// SetSettings merges a patch into settings and applies side effects.
func (d *Daemon) SetSettings(patch json.RawMessage) (model.Settings, error) {
	st := d.cfg.Settings()
	if err := config.MergePatch(&st, patch); err != nil {
		return st, invalid(err)
	}
	if !slices.Contains([]string{"debug", "info", "notice", "warn", "error"}, st.Logs.Level) {
		return st, api.Errorf(api.CodeInvalidParams, "invalid logs.level %q", st.Logs.Level)
	}
	if st.Network.BwSchedule == nil {
		st.Network.BwSchedule = []model.BwWindow{}
	}
	if err := d.cfg.PutSettings(st); err != nil {
		return st, err
	}
	if d.opt.Engine == nil {
		engine.SetLogLevel(st.Logs.Level)
	}
	if st.Engine.MemoryLimitMB > 0 {
		debug.SetMemoryLimit(int64(st.Engine.MemoryLimitMB) << 20)
	}
	d.mu.Lock()
	d.publishAllLocked()
	d.mu.Unlock()
	d.applyBandwidth()
	d.reschedule()
	return st, nil
}

// ConfigBundle is the secret-free export format (config.export/import).
type ConfigBundle struct {
	Version  int              `json:"version"`
	Daemon   string           `json:"daemonVersion,omitempty"`
	Settings *model.Settings  `json:"settings,omitempty"`
	Jobs     []model.Job      `json:"jobs"`
	Accounts []map[string]any `json:"accounts"`
}

func (d *Daemon) exportConfig() ConfigBundle {
	st := d.cfg.Settings()
	b := ConfigBundle{Version: config.SchemaVersion, Daemon: version.Version, Settings: &st, Jobs: d.cfg.Jobs(), Accounts: []map[string]any{}}
	for _, a := range d.cfg.Accounts() {
		b.Accounts = append(b.Accounts, map[string]any{"id": a.ID, "provider": a.Provider, "name": a.Name})
	}
	if b.Jobs == nil {
		b.Jobs = []model.Job{}
	}
	return b
}

func (d *Daemon) importConfig(b ConfigBundle) (any, error) {
	if b.Settings != nil {
		raw, _ := json.Marshal(b.Settings)
		if _, err := d.SetSettings(raw); err != nil {
			return nil, err
		}
	}
	imported, skipped := 0, []string{}
	for _, j := range b.Jobs {
		if !d.accountExists(j.AccountID) {
			skipped = append(skipped, fmt.Sprintf("%s: account %s not configured", j.Name, j.AccountID))
			continue
		}
		j.ID, j.Status = "", nil
		raw, _ := json.Marshal(j)
		if _, err := d.CreateJob(raw); err != nil {
			skipped = append(skipped, j.Name+": "+strings.TrimSpace(err.Error()))
			continue
		}
		imported++
	}
	return map[string]any{"imported": imported, "skipped": skipped}, nil
}
