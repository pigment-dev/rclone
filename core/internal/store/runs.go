package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// ErrNotFound is returned for missing rows.
var ErrNotFound = errors.New("not found")

// PutRun inserts or replaces a run.
func (s *Store) PutRun(ctx context.Context, jobID string, r model.RunSummary) error {
	var ended any
	if r.EndedAt != nil {
		ended = ms(*r.EndedAt)
	}
	_, err := s.db.ExecContext(ctx, `INSERT OR REPLACE INTO runs(id, job_id, started_at, ended_at, ok, error, bytes, files, deletes, conflicts, dry_run)
		VALUES(?,?,?,?,?,?,?,?,?,?,?)`, r.ID, jobID, ms(r.StartedAt), ended, b2i(r.OK), nullStr(r.Error), r.Bytes, r.Files, r.Deletes, r.Conflicts, b2i(r.DryRun))
	return err
}

// Runs returns the latest runs of a job, newest first.
func (s *Store) Runs(ctx context.Context, jobID string, limit int) ([]model.RunSummary, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, started_at, ended_at, ok, error, bytes, files, deletes, conflicts, dry_run
		FROM runs WHERE job_id = ? ORDER BY started_at DESC LIMIT ?`, jobID, limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := []model.RunSummary{}
	for rows.Next() {
		var r model.RunSummary
		var started int64
		var ended sql.NullInt64
		var ok, dry int
		var e sql.NullString
		if err := rows.Scan(&r.ID, &started, &ended, &ok, &e, &r.Bytes, &r.Files, &r.Deletes, &r.Conflicts, &dry); err != nil {
			return nil, err
		}
		r.StartedAt = fromMs(started)
		if ended.Valid {
			t := fromMs(ended.Int64)
			r.EndedAt = &t
		}
		r.OK, r.DryRun, r.Error = ok == 1, dry == 1, strPtr(e)
		out = append(out, r)
	}
	return out, rows.Err()
}

// LastRun returns the latest run of a job, or nil.
func (s *Store) LastRun(ctx context.Context, jobID string) *model.RunSummary {
	runs, err := s.Runs(ctx, jobID, 1)
	if err != nil || len(runs) == 0 {
		return nil
	}
	return &runs[0]
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// PutAction inserts or replaces an action.
func (s *Store) PutAction(ctx context.Context, a model.Action) error {
	choices, _ := json.Marshal(a.Choices)
	data, _ := json.Marshal(a.Data)
	_, err := s.db.ExecContext(ctx, `INSERT OR REPLACE INTO actions(id, job_id, kind, severity, title, message, path, created_at, resolved, choices, data)
		VALUES(?,?,?,?,?,?,?,?,?,?,?)`, a.ID, nullStr(a.JobID), a.Kind, a.Severity, a.Title, Redact(a.Message), nullStr(a.Path), ms(a.CreatedAt), b2i(a.Resolved), string(choices), string(data))
	return err
}

// Action returns one action.
func (s *Store) Action(ctx context.Context, id string) (model.Action, error) {
	as, err := s.queryActions(ctx, `WHERE id = ?`, id)
	if err != nil {
		return model.Action{}, err
	}
	if len(as) == 0 {
		return model.Action{}, ErrNotFound
	}
	return as[0], nil
}

// Actions lists actions, newest first.
func (s *Store) Actions(ctx context.Context, includeResolved bool) ([]model.Action, error) {
	if includeResolved {
		return s.queryActions(ctx, `ORDER BY created_at DESC LIMIT 500`)
	}
	return s.queryActions(ctx, `WHERE resolved = 0 ORDER BY created_at DESC LIMIT 500`)
}

// OpenActions returns unresolved actions of a kind for a job.
func (s *Store) OpenActions(ctx context.Context, jobID, kind string) ([]model.Action, error) {
	return s.queryActions(ctx, `WHERE resolved = 0 AND job_id = ? AND kind = ? ORDER BY created_at DESC`, jobID, kind)
}

func (s *Store) queryActions(ctx context.Context, tail string, args ...any) ([]model.Action, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, kind, severity, title, message, path, created_at, resolved, choices, data FROM actions `+tail, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := []model.Action{}
	for rows.Next() {
		var a model.Action
		var job, path sql.NullString
		var created int64
		var resolved int
		var choices, data string
		if err := rows.Scan(&a.ID, &job, &a.Kind, &a.Severity, &a.Title, &a.Message, &path, &created, &resolved, &choices, &data); err != nil {
			return nil, err
		}
		a.JobID, a.Path, a.CreatedAt, a.Resolved = strPtr(job), strPtr(path), fromMs(created), resolved == 1
		_ = json.Unmarshal([]byte(choices), &a.Choices)
		_ = json.Unmarshal([]byte(data), &a.Data)
		if a.Choices == nil {
			a.Choices = []model.Choice{}
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
