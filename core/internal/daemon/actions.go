package daemon

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/pigment-dev/rclone/core/internal/accounts"
	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/engine"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/store"
)

var (
	chDismiss    = model.Choice{ID: "dismiss", Label: "Dismiss"}
	chRetry      = model.Choice{ID: "retry", Label: "Retry"}
	chRunAnyway  = model.Choice{ID: "runAnyway", Label: "Run anyway"}
	chReconnect  = model.Choice{ID: "reconnect", Label: "Reconnect"}
	chKeepLocal  = model.Choice{ID: "keepLocal", Label: "Keep this Mac's version"}
	chKeepRemote = model.Choice{ID: "keepRemote", Label: "Keep the cloud version"}
	chKeepBoth   = model.Choice{ID: "keepBoth", Label: "Keep both"}
)

// AddAction stores and publishes a new action.
func (d *Daemon) AddAction(a model.Action) model.Action {
	if a.ID == "" {
		a.ID = accounts.NewID("act")
	}
	if a.CreatedAt.IsZero() {
		a.CreatedAt = time.Now().UTC()
	}
	if a.Choices == nil {
		a.Choices = []model.Choice{chDismiss}
	}
	_ = d.db.PutAction(context.Background(), a)
	d.srv.Publish("action.new", map[string]any{"action": a})
	return a
}

// upsertAction updates the open action of the same kind for the job, or
// creates one, so repeated failures do not flood the Action Center.
func (d *Daemon) upsertAction(a model.Action) {
	if a.JobID != nil {
		open, _ := d.db.OpenActions(context.Background(), *a.JobID, a.Kind)
		if len(open) > 0 {
			cur := open[0]
			cur.Title, cur.Message, cur.Severity, cur.Choices, cur.Data = a.Title, a.Message, a.Severity, a.Choices, a.Data
			_ = d.db.PutAction(context.Background(), cur)
			d.srv.Publish("action.updated", map[string]any{"action": cur})
			return
		}
	}
	d.AddAction(a)
}

// resolveOpen auto-resolves open actions of kinds for a job.
func (d *Daemon) resolveOpen(jobID string, kinds ...string) {
	for _, k := range kinds {
		open, _ := d.db.OpenActions(context.Background(), jobID, k)
		for _, a := range open {
			a.Resolved = true
			_ = d.db.PutAction(context.Background(), a)
			d.srv.Publish("action.updated", map[string]any{"action": a})
		}
	}
}

// recordOutcome turns a run result into Action Center items.
func (d *Daemon) recordOutcome(j model.Job, req runReq, res engine.RunResult) {
	jid := j.ID
	for _, c := range res.Conflicts {
		if j.ConflictPolicy == model.ConflictAsk {
			p := c.Path
			d.AddAction(model.Action{
				JobID: &jid, Kind: model.ActConflict, Severity: "warning",
				Title:   "Edited on both sides: " + baseName(c.Path),
				Message: fmt.Sprintf("%q changed on this computer and in the cloud since the last sync of %q. Both versions were kept; choose which one wins.", c.Path, j.Name),
				Path:    &p, Choices: []model.Choice{chKeepLocal, chKeepRemote, chKeepBoth},
				Data: map[string]string{"path": c.Path, "localCopy": c.LocalCopy, "remoteCopy": c.RemoteCopy},
			})
		} else {
			d.logf("notice", &jid, &req.RunID, "Conflict on %s resolved by policy %q (copies: %s %s)", c.Path, j.ConflictPolicy, c.LocalCopy, c.RemoteCopy)
		}
	}
	msg := ""
	if res.Err != nil {
		msg = res.Err.Error()
	}
	switch res.Fail {
	case engine.FailNone:
		if !req.DryRun {
			d.resolveOpen(jid, model.ActError, model.ActAuthExpired, model.ActMaxDeleteAbort, model.ActQuotaFull, model.ActPermission)
			d.setAccountStatus(j.AccountID, model.AccountOK, nil)
		}
	case engine.FailCancelled:
	case engine.FailMaxDelete:
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActMaxDeleteAbort, Severity: "warning",
			Title:   fmt.Sprintf("%q stopped to protect your files", j.Name),
			Message: msg + ". Nothing was deleted. Check that the folder is not missing or emptied by mistake, then choose Run anyway.",
			Choices: []model.Choice{chRunAnyway, chDismiss}})
	case engine.FailAuth:
		acc, _ := d.cfg.Account(j.AccountID)
		d.setAccountStatus(j.AccountID, model.AccountNeedsAuth, &msg)
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActAuthExpired, Severity: "error",
			Title:   fmt.Sprintf("Reconnect %s", acc.Name),
			Message: fmt.Sprintf("The sign-in for %q expired or was revoked, so %q cannot sync. %s", acc.Name, j.Name, msg),
			Choices: []model.Choice{chReconnect, chDismiss}, Data: map[string]string{"accountId": j.AccountID}})
	case engine.FailQuota:
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActQuotaFull, Severity: "error",
			Title: "Storage is full", Message: msg, Choices: []model.Choice{chRetry, chDismiss}})
	case engine.FailPermission:
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActPermission, Severity: "error",
			Title: "Permission denied", Message: msg + ". On macOS, grant Full Disk Access if the folder is protected.", Choices: []model.Choice{chRetry, chDismiss}})
	case engine.FailNeedsResync:
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActError, Severity: "warning",
			Title:   fmt.Sprintf("%q needs a new two-way baseline", j.Name),
			Message: "The two-way sync state is missing or was interrupted. Run a resync to rebuild it; nothing is deleted during a resync.",
			Choices: []model.Choice{{ID: "retry", Label: "Run resync"}, chDismiss}, Data: map[string]string{"resync": "1"}})
	default:
		d.upsertAction(model.Action{JobID: &jid, Kind: model.ActError, Severity: "error",
			Title: fmt.Sprintf("%q failed", j.Name), Message: msg, Choices: []model.Choice{chRetry, chDismiss}})
	}
}

func (d *Daemon) setAccountStatus(id, status string, errMsg *string) {
	acc, ok := d.cfg.Account(id)
	if !ok || (acc.Status == status && (errMsg == nil) == (acc.Error == nil)) {
		return
	}
	acc.Status, acc.Error = status, errMsg
	_ = d.cfg.PutAccount(acc)
}

// ResolveAction applies a choice to an action.
func (d *Daemon) ResolveAction(ctx context.Context, id, choice string) (model.Action, error) {
	a, err := d.db.Action(ctx, id)
	if err == store.ErrNotFound {
		return a, api.Errorf(api.CodeNotFound, "action %s not found", id)
	} else if err != nil {
		return a, err
	}
	if choice != "dismiss" && !slices.ContainsFunc(a.Choices, func(c model.Choice) bool { return c.ID == choice }) {
		return a, api.Errorf(api.CodeInvalidParams, "choice %q not offered for this action", choice)
	}
	if !a.Resolved && choice != "dismiss" && a.JobID != nil {
		jid := *a.JobID
		j, ok := d.cfg.Job(jid)
		switch a.Kind {
		case model.ActConflict:
			if !ok {
				return a, api.Errorf(api.CodeNotFound, "job %s not found", jid)
			}
			c := engine.Conflict{Path: a.Data["path"], LocalCopy: a.Data["localCopy"], RemoteCopy: a.Data["remoteCopy"]}
			if err := d.eng.ResolveConflict(ctx, j, c, choice); err != nil {
				return a, err
			}
			d.logf("notice", &jid, nil, "Conflict on %s resolved: %s", c.Path, choice)
			if choice != "keepBoth" {
				// Removing the losing copies is intended: bypass the delete guard.
				_, _ = d.TriggerRun(jid, runReq{Reason: "conflict resolved", Force: true})
			}
		case model.ActMaxDeleteAbort:
			if _, err := d.TriggerRun(jid, runReq{Manual: true, Force: true, Reason: "run anyway after delete guard"}); err != nil {
				return a, err
			}
		default:
			if choice == "retry" {
				req := runReq{Manual: true, Reason: "retry from Action Center", Resync: a.Data["resync"] == "1"}
				if _, err := d.TriggerRun(jid, req); err != nil {
					return a, err
				}
			}
		}
	}
	a.Resolved = true
	if err := d.db.PutAction(ctx, a); err != nil {
		return a, err
	}
	d.srv.Publish("action.updated", map[string]any{"action": a})
	return a, nil
}

func baseName(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}
