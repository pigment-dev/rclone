package accounts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/rc"
	"github.com/rclone/rclone/lib/oauthutil"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// Question asks the user for one more config value.
type Question struct {
	Name    string              `json:"name"`
	Label   string              `json:"label"`
	Help    string              `json:"help"`
	Type    string              `json:"type"`
	Options []model.FieldOption `json:"options"`
	Default any                 `json:"default"`
}

// Result is the reply of accounts.add.start / continue.
type Result struct {
	State     string         `json:"state"` // done|needsOAuth|needsInput
	SessionID string         `json:"sessionId,omitempty"`
	AuthURL   string         `json:"authUrl,omitempty"`
	Question  *Question      `json:"question,omitempty"`
	Account   *model.Account `json:"account,omitempty"`
}

// Flow drives account creation.
type Flow interface {
	Start(ctx context.Context, accountID, provider, name string, fields map[string]any) (*Result, error)
	Continue(ctx context.Context, sessionID string, answer any) (*Result, error)
	Cancel(sessionID string) error
	// Reconnect re-runs authentication for an existing account.
	Reconnect(ctx context.Context, acc model.Account) (*Result, error)
}

// ErrSessionNotFound is returned for unknown or expired sessions.
var ErrSessionNotFound = errors.New("account session not found or expired")

const sessionTTL = 15 * time.Minute

type stepOut struct {
	out *fs.ConfigOut
	err error
}

type session struct {
	mu                                    sync.Mutex // serialises Continue/Cancel on one session
	id, accountID, provider, name, remote string
	state                                 string // rclone state awaiting an answer
	question                              *fs.Option
	authURL                               string
	oauthDone                             chan stepOut // non-nil while OAuth runs
	expires                               time.Time
	keep                                  bool // reconnect: never delete the remote
}

// RcloneFlow is the real Flow backed by rclone's config state machine.
type RcloneFlow struct {
	mu       sync.Mutex
	sessions map[string]*session
	oauthMu  sync.Mutex // rclone's loopback server (port 53682) is a singleton
	urlCh    chan string
}

// NewRcloneFlow returns a Flow and hooks rclone's browser opener so the
// auth URL is handed to the client instead of opening a browser here.
func NewRcloneFlow() *RcloneFlow {
	f := &RcloneFlow{sessions: map[string]*session{}, urlCh: make(chan string, 1)}
	oauthutil.OpenURL = func(url string) error {
		select {
		case f.urlCh <- url:
		default:
		}
		return nil
	}
	return f
}

var nonInteractive = config.UpdateRemoteOpt{NonInteractive: true, Obscure: true}

// Start creates the remote and runs the config state machine.
func (f *RcloneFlow) Start(ctx context.Context, accountID, provider, name string, fields map[string]any) (*Result, error) {
	rn, ok := RcloneName(provider)
	if !ok {
		return nil, fmt.Errorf("unknown provider %q", provider)
	}
	s := &session{id: "ses_" + randID(), accountID: accountID, provider: provider, name: name, remote: "pd_" + accountID, expires: time.Now().Add(sessionTTL)}
	params := rc.Params{}
	for k, v := range fields {
		if v != nil && fmt.Sprint(v) != "" {
			params[k] = v
		}
	}
	out, err := config.CreateRemote(ctx, s.remote, rn, params, nonInteractive)
	if err != nil {
		config.DeleteRemote(s.remote)
		return nil, err
	}
	f.mu.Lock()
	f.gcLocked()
	f.sessions[s.id] = s
	f.mu.Unlock()
	return f.advance(s, out)
}

// Continue answers the pending question, or polls a running OAuth flow.
func (f *RcloneFlow) Continue(ctx context.Context, id string, answer any) (*Result, error) {
	f.mu.Lock()
	s := f.sessions[id]
	f.mu.Unlock()
	if s == nil {
		return nil, ErrSessionNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.oauthDone != nil {
		select {
		case r := <-s.oauthDone:
			s.oauthDone = nil
			if r.err != nil {
				f.drop(s)
				return nil, r.err
			}
			return f.advance(s, r.out)
		case <-time.After(200 * time.Millisecond):
			return &Result{State: "needsOAuth", SessionID: s.id, AuthURL: s.authURL}, nil
		}
	}
	if s.question == nil {
		return nil, errors.New("nothing to continue")
	}
	val := ""
	if answer != nil {
		val = fmt.Sprint(answer)
	} else if s.question.Default != nil {
		val = fmt.Sprint(s.question.Default)
	}
	out, err := config.UpdateRemote(ctx, s.remote, nil, config.UpdateRemoteOpt{NonInteractive: true, Obscure: true, Continue: true, State: s.state, Result: val})
	if err != nil {
		f.drop(s)
		return nil, err
	}
	return f.advance(s, out)
}

// Cancel aborts a session and removes the half-configured remote.
func (f *RcloneFlow) Cancel(id string) error {
	f.mu.Lock()
	s := f.sessions[id]
	f.mu.Unlock()
	if s == nil {
		return ErrSessionNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.oauthDone != nil {
		if call := rc.Calls.Get("config/oauthstop"); call != nil {
			_, _ = call.Fn(context.Background(), rc.Params{})
		}
		s.oauthDone = nil
	}
	f.drop(s)
	return nil
}

func (f *RcloneFlow) drop(s *session) {
	f.mu.Lock()
	delete(f.sessions, s.id)
	f.mu.Unlock()
	if !s.keep {
		config.DeleteRemote(s.remote)
	}
}

// Reconnect re-authenticates an existing remote (refreshes the token).
func (f *RcloneFlow) Reconnect(ctx context.Context, acc model.Account) (*Result, error) {
	s := &session{id: "ses_" + randID(), accountID: acc.ID, provider: acc.Provider, name: acc.Name, remote: acc.Remote, expires: time.Now().Add(sessionTTL), keep: true}
	out, err := config.UpdateRemote(ctx, s.remote, nil, nonInteractive)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.gcLocked()
	f.sessions[s.id] = s
	f.mu.Unlock()
	return f.advance(s, out)
}

// advance auto-answers plumbing questions and returns the next step.
func (f *RcloneFlow) advance(s *session, out *fs.ConfigOut) (*Result, error) {
	for {
		if out == nil || (out.State == "" && out.Option == nil) {
			f.mu.Lock()
			delete(f.sessions, s.id)
			f.mu.Unlock()
			acc := &model.Account{ID: s.accountID, Provider: s.provider, Name: s.name, Remote: s.remote, Status: model.AccountOK, CreatedAt: time.Now().UTC()}
			return &Result{State: "done", Account: acc}, nil
		}
		if out.Option == nil {
			// State transition without a question: keep going.
			var err error
			out, err = f.step(s, out.State, out.Result)
			if err != nil {
				return nil, err
			}
			continue
		}
		s.state, s.question = out.State, out.Option
		switch out.Option.Name {
		case "config_is_local":
			return f.startOAuth(s)
		case "config_refresh_token":
			var err error
			if out, err = f.step(s, out.State, "true"); err != nil {
				return nil, err
			}
			continue
		case "config_fs_advanced":
			var err error
			if out, err = f.step(s, out.State, "false"); err != nil {
				return nil, err
			}
			continue
		}
		q := toQuestion(out.Option)
		if out.Error != "" {
			q.Help = out.Error + "\n\n" + q.Help
		}
		return &Result{State: "needsInput", SessionID: s.id, Question: q}, nil
	}
}

func (f *RcloneFlow) step(s *session, state, result string) (*fs.ConfigOut, error) {
	out, err := config.UpdateRemote(context.Background(), s.remote, nil, config.UpdateRemoteOpt{NonInteractive: true, Obscure: true, Continue: true, State: state, Result: result})
	if err != nil {
		f.drop(s)
	}
	return out, err
}

// startOAuth answers "use a local browser" in the background; that call
// blocks inside rclone until the loopback server receives the token.
func (f *RcloneFlow) startOAuth(s *session) (*Result, error) {
	if !f.oauthMu.TryLock() {
		return nil, errors.New("another account sign-in is in progress; finish or cancel it first")
	}
	select { // discard a stale URL
	case <-f.urlCh:
	default:
	}
	done := make(chan stepOut, 1)
	s.oauthDone = done
	state := s.state
	go func() {
		out, err := config.UpdateRemote(context.Background(), s.remote, nil, config.UpdateRemoteOpt{NonInteractive: true, Obscure: true, Continue: true, State: state, Result: "true"})
		done <- stepOut{out, err}
		f.oauthMu.Unlock()
	}()
	select {
	case u := <-f.urlCh:
		s.authURL = u
		return &Result{State: "needsOAuth", SessionID: s.id, AuthURL: u}, nil
	case r := <-done:
		s.oauthDone = nil
		if r.err != nil {
			f.drop(s)
			return nil, r.err
		}
		return f.advance(s, r.out)
	case <-time.After(20 * time.Second):
		return &Result{State: "needsOAuth", SessionID: s.id, AuthURL: s.authURL}, nil
	}
}

func toQuestion(o *fs.Option) *Question {
	fld := toField(o)
	help := o.Help
	if strings.TrimSpace(help) == "" {
		help = fld.Label
	}
	return &Question{Name: o.Name, Label: fld.Label, Help: help, Type: fld.Type, Options: fld.Options, Default: fld.Default}
}

func (f *RcloneFlow) gcLocked() {
	now := time.Now()
	for id, s := range f.sessions {
		if now.After(s.expires) && s.oauthDone == nil {
			delete(f.sessions, id)
			if !s.keep {
				config.DeleteRemote(s.remote)
			}
		}
	}
}
