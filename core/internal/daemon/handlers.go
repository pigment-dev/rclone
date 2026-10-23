package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"runtime"
	"time"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/platform"
	"github.com/pigment-dev/rclone/core/internal/version"
)

// method registers a typed handler.
func method[P any](d *Daemon, name string, fn func(ctx context.Context, c *api.Conn, p P) (any, error)) {
	d.srv.Handle(name, func(ctx context.Context, c *api.Conn, raw json.RawMessage) (any, error) {
		var p P
		if err := api.Bind(raw, &p); err != nil {
			return nil, err
		}
		return fn(ctx, c, p)
	})
}

type idParam struct {
	ID string `json:"id"`
}

func (d *Daemon) registerHandlers() {
	method(d, "hello", func(_ context.Context, c *api.Conn, p struct {
		Client  string `json:"client"`
		Version string `json:"version"`
	}) (any, error) {
		c.Authenticate(p.Client)
		return d.helloInfo(), nil
	})
	method(d, "subscribe", func(_ context.Context, c *api.Conn, p struct {
		Topics []string `json:"topics"`
	}) (any, error) {
		c.Subscribe(p.Topics)
		return api.OK, nil
	})
	method(d, "unsubscribe", func(_ context.Context, c *api.Conn, p struct {
		Topics []string `json:"topics"`
	}) (any, error) {
		c.Unsubscribe(p.Topics)
		return api.OK, nil
	})
	method(d, "daemon.info", func(context.Context, *api.Conn, struct{}) (any, error) {
		info := d.helloInfo()
		d.mu.Lock()
		info["jobsRunning"] = d.running
		d.mu.Unlock()
		info["uptimeSec"] = int64(time.Since(d.startedAt).Seconds())
		info["rssBytes"] = platform.RSS()
		info["goroutines"] = runtime.NumGoroutine()
		return info, nil
	})
	method(d, "daemon.shutdown", func(context.Context, *api.Conn, struct{}) (any, error) {
		go func() {
			time.Sleep(100 * time.Millisecond) // let the reply flush
			d.Stop()
		}()
		return api.OK, nil
	})
	method(d, "system.state", func(_ context.Context, _ *api.Conn, st model.SystemState) (any, error) {
		if !d.opt.Demo { // demo mode keeps its simulated environment
			d.setSystemState(st)
		}
		return api.OK, nil
	})
	d.registerAccountHandlers()
	d.registerJobHandlers()
	d.registerMiscHandlers()
}

func (d *Daemon) helloInfo() map[string]any {
	return map[string]any{
		"daemonVersion": version.Version,
		"rcloneVersion": d.eng.RcloneVersion(),
		"protocol":      version.Protocol,
		"os":            runtime.GOOS,
		"arch":          runtime.GOARCH,
		"dataDir":       d.opt.Paths.DataDir,
		"pid":           os.Getpid(),
		"startedAt":     d.startedAt,
		"demo":          d.opt.Demo,
	}
}

func notFound(what, id string) error {
	return api.Errorf(api.CodeNotFound, "%s %s not found", what, id)
}

func providerErr(err error) error {
	var e *api.Error
	if errors.As(err, &e) {
		return e
	}
	return &api.Error{Code: api.CodeProvider, Message: err.Error()}
}

func (d *Daemon) registerAccountHandlers() {
	method(d, "accounts.providers", func(context.Context, *api.Conn, struct{}) (any, error) {
		return map[string]any{"providers": accounts.Providers()}, nil
	})
	method(d, "accounts.list", func(context.Context, *api.Conn, struct{}) (any, error) {
		list := d.cfg.Accounts()
		if list == nil {
			list = []model.Account{}
		}
		return map[string]any{"accounts": list}, nil
	})
	method(d, "accounts.add.start", func(ctx context.Context, _ *api.Conn, p struct {
		Provider string         `json:"provider"`
		Name     string         `json:"name"`
		Fields   map[string]any `json:"fields"`
	}) (any, error) {
		if p.Provider == "" {
			return nil, api.Errorf(api.CodeInvalidParams, "provider is required")
		}
		if p.Name == "" {
			p.Name = p.Provider
		}
		res, err := d.flow.Start(ctx, accounts.NewID("acc"), p.Provider, p.Name, p.Fields)
		if err != nil {
			return nil, providerErr(err)
		}
		return d.finishAdd(res), nil
	})
	method(d, "accounts.add.continue", func(ctx context.Context, _ *api.Conn, p struct {
		SessionID string `json:"sessionId"`
		Answer    any    `json:"answer"`
	}) (any, error) {
		res, err := d.flow.Continue(ctx, p.SessionID, p.Answer)
		if errors.Is(err, accounts.ErrSessionNotFound) {
			return nil, notFound("session", p.SessionID)
		}
		if err != nil {
			return nil, providerErr(err)
		}
		return d.finishAdd(res), nil
	})
	method(d, "accounts.add.cancel", func(_ context.Context, _ *api.Conn, p struct {
		SessionID string `json:"sessionId"`
	}) (any, error) {
		if err := d.flow.Cancel(p.SessionID); err != nil {
			return nil, notFound("session", p.SessionID)
		}
		return api.OK, nil
	})
	method(d, "accounts.reconnect", func(ctx context.Context, _ *api.Conn, p idParam) (any, error) {
		acc, ok := d.cfg.Account(p.ID)
		if !ok {
			return nil, notFound("account", p.ID)
		}
		res, err := d.flow.Reconnect(ctx, acc)
		if err != nil {
			return nil, providerErr(err)
		}
		return d.finishAdd(res), nil
	})
	method(d, "accounts.test", func(ctx context.Context, _ *api.Conn, p idParam) (any, error) {
		acc, ok := d.cfg.Account(p.ID)
		if !ok {
			return nil, notFound("account", p.ID)
		}
		lat, err := d.eng.Test(ctx, acc.Remote)
		if err != nil {
			msg := err.Error()
			status := model.AccountError
			if engineAuth(err) {
				status = model.AccountNeedsAuth
			}
			d.setAccountStatus(acc.ID, status, &msg)
			return map[string]any{"ok": false, "error": msg, "latencyMs": 0}, nil
		}
		d.setAccountStatus(acc.ID, model.AccountOK, nil)
		return map[string]any{"ok": true, "latencyMs": lat.Milliseconds()}, nil
	})
	method(d, "accounts.quota", func(ctx context.Context, _ *api.Conn, p idParam) (any, error) {
		acc, ok := d.cfg.Account(p.ID)
		if !ok {
			return nil, notFound("account", p.ID)
		}
		q, err := d.eng.About(ctx, acc.Remote)
		if err != nil {
			return nil, providerErr(err)
		}
		acc.Quota = q
		_ = d.cfg.PutAccount(acc)
		return map[string]any{"quota": q}, nil
	})
	method(d, "accounts.refresh", func(ctx context.Context, _ *api.Conn, p idParam) (any, error) {
		acc, err := d.refreshAccountInfo(ctx, p.ID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"account": acc}, nil
	})
	method(d, "accounts.rename", func(_ context.Context, _ *api.Conn, p struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}) (any, error) {
		acc, ok := d.cfg.Account(p.ID)
		if !ok {
			return nil, notFound("account", p.ID)
		}
		if p.Name == "" {
			return nil, api.Errorf(api.CodeInvalidParams, "name is required")
		}
		acc.Name = p.Name
		if err := d.cfg.PutAccount(acc); err != nil {
			return nil, err
		}
		return map[string]any{"account": acc}, nil
	})
	method(d, "accounts.remove", func(_ context.Context, _ *api.Conn, p struct {
		ID    string `json:"id"`
		Force bool   `json:"force"`
	}) (any, error) {
		acc, ok := d.cfg.Account(p.ID)
		if !ok {
			return nil, notFound("account", p.ID)
		}
		var users []string
		for _, j := range d.cfg.Jobs() {
			if j.AccountID == p.ID {
				users = append(users, j.ID)
			}
		}
		if len(users) > 0 && !p.Force {
			return nil, &api.Error{Code: api.CodeConflict, Message: "account is used by jobs", Data: map[string]any{"jobs": users}}
		}
		for _, id := range users {
			d.deleteJob(id)
		}
		d.eng.DeleteRemote(acc.Remote)
		if err := d.cfg.DeleteAccount(p.ID); err != nil {
			return nil, err
		}
		d.logf("notice", nil, nil, "Account %q (%s) removed", acc.Name, acc.Provider)
		return api.OK, nil
	})
}

// finishAdd persists a newly completed account.
func (d *Daemon) finishAdd(res *accounts.Result) *accounts.Result {
	if res.State != "done" || res.Account == nil {
		return res
	}
	acc := *res.Account
	if old, ok := d.cfg.Account(acc.ID); ok { // reconnect keeps name and age
		acc.Name, acc.CreatedAt, acc.Quota = old.Name, old.CreatedAt, old.Quota
	}
	acc.Status, acc.Error = model.AccountOK, nil
	if err := d.cfg.PutAccount(acc); err != nil {
		d.logf("error", nil, nil, "Saving account %q failed: %v", acc.Name, err)
	}
	res.Account = &acc
	d.logf("notice", nil, nil, "Account %q (%s) connected", acc.Name, acc.Provider)
	go func(id string) {
		ctx, cancel := context.WithTimeout(d.ctx, time.Minute)
		defer cancel()
		_, _ = d.refreshAccountInfo(ctx, id)
	}(acc.ID)
	for _, j := range d.cfg.Jobs() {
		if j.AccountID == acc.ID {
			d.resolveOpen(j.ID, model.ActAuthExpired)
		}
	}
	return res
}

func engineAuth(err error) bool {
	return engine.Classify(err) == engine.FailAuth
}

// refreshAccountInfo fetches storage usage and the signed-in user (where the
// provider reports them) and saves them on the account.
func (d *Daemon) refreshAccountInfo(ctx context.Context, id string) (model.Account, error) {
	acc, ok := d.cfg.Account(id)
	if !ok {
		return acc, notFound("account", id)
	}
	q, qerr := d.eng.About(ctx, acc.Remote)
	who, werr := d.eng.Identity(ctx, acc.Remote)
	if qerr != nil && werr != nil && !errors.Is(qerr, engine.ErrUnsupported) {
		return acc, providerErr(qerr)
	}
	acc, _ = d.cfg.Account(id) // re-read: status may have changed meanwhile
	if qerr == nil {
		acc.Quota = q
	}
	if werr == nil && who != nil && (who.Email != "" || who.Name != "") {
		acc.User = who
	}
	if err := d.cfg.PutAccount(acc); err != nil {
		return acc, err
	}
	return acc, nil
}
