package store

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// Levels in increasing severity.
var levels = []string{"debug", "info", "notice", "warn", "error"}

// LevelNum maps a level name to its rank (unknown → info).
func LevelNum(l string) int {
	for i, n := range levels {
		if n == l {
			return i
		}
	}
	if l == "warning" {
		return 3
	}
	return 1
}

// LevelName maps a rank to its name.
func LevelName(n int) string {
	if n < 0 || n >= len(levels) {
		return "info"
	}
	return levels[n]
}

const (
	flushEvery = 500 * time.Millisecond
	flushBatch = 256
	maxPending = 20000 // drop oldest beyond this to bound memory
)

// AddLog queues a log line for a batched insert. The message is redacted.
func (s *Store) AddLog(l model.LogLine) model.LogLine {
	l.Msg = Redact(l.Msg)
	if l.TS.IsZero() {
		l.TS = time.Now().UTC()
	}
	s.mu.Lock()
	s.pending = append(s.pending, l)
	if len(s.pending) > maxPending {
		s.pending = s.pending[len(s.pending)-maxPending:]
	}
	n := len(s.pending)
	s.mu.Unlock()
	if n == 1 || n >= flushBatch {
		select {
		case s.flushCh <- struct{}{}:
		default:
		}
	}
	return l
}

// flusher batches inserts: it sleeps until the first pending line, then
// waits flushEvery to collect more. An idle daemon never wakes up.
func (s *Store) flusher() {
	defer s.wg.Done()
	for {
		select {
		case <-s.done:
			s.Flush()
			return
		case <-s.flushCh:
		}
		t := time.NewTimer(flushEvery)
		select {
		case <-s.done:
			t.Stop()
			s.Flush()
			return
		case <-t.C:
		}
		s.Flush()
	}
}

// Flush writes pending log lines in one transaction.
func (s *Store) Flush() {
	s.mu.Lock()
	batch := s.pending
	s.pending = nil
	s.mu.Unlock()
	if len(batch) == 0 {
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		return
	}
	stmt, err := tx.Prepare(`INSERT INTO logs(ts, level, job_id, run_id, msg, path) VALUES(?,?,?,?,?,?)`)
	if err != nil {
		_ = tx.Rollback()
		return
	}
	for _, l := range batch {
		_, _ = stmt.Exec(ms(l.TS), LevelNum(l.Level), nullStr(l.JobID), nullStr(l.RunID), l.Msg, nullStr(l.Path))
	}
	_ = stmt.Close()
	_ = tx.Commit()
}

// LogQuery filters log.query.
type LogQuery struct {
	JobID  string     `json:"jobId,omitempty"`
	RunID  string     `json:"runId,omitempty"`
	Level  string     `json:"level,omitempty"`
	Search string     `json:"search,omitempty"`
	Since  *time.Time `json:"since,omitempty"`
	Until  *time.Time `json:"until,omitempty"`
	Before *time.Time `json:"before,omitempty"`
	Limit  int        `json:"limit,omitempty"`
}

// QueryLogs returns matching lines, newest first.
func (s *Store) QueryLogs(ctx context.Context, q LogQuery) ([]model.LogLine, error) {
	s.Flush()
	var where []string
	var args []any
	if q.JobID != "" {
		where = append(where, "job_id = ?")
		args = append(args, q.JobID)
	}
	if q.RunID != "" {
		where = append(where, "run_id = ?")
		args = append(args, q.RunID)
	}
	if q.Level != "" {
		where = append(where, "level >= ?")
		args = append(args, LevelNum(q.Level))
	}
	if q.Search != "" {
		where = append(where, `(msg LIKE ? ESCAPE '\' OR path LIKE ? ESCAPE '\')`)
		like := "%" + escapeLike(q.Search) + "%"
		args = append(args, like, like)
	}
	if q.Since != nil {
		where = append(where, "ts >= ?")
		args = append(args, ms(*q.Since))
	}
	if q.Until != nil {
		where = append(where, "ts <= ?")
		args = append(args, ms(*q.Until))
	}
	if q.Before != nil {
		where = append(where, "ts < ?")
		args = append(args, ms(*q.Before))
	}
	limit := q.Limit
	if limit <= 0 || limit > 5000 {
		limit = 500
	}
	sqlq := `SELECT ts, level, job_id, run_id, msg, path FROM logs`
	if len(where) > 0 {
		sqlq += " WHERE " + strings.Join(where, " AND ")
	}
	sqlq += " ORDER BY ts DESC, id DESC LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, sqlq, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := []model.LogLine{}
	for rows.Next() {
		var ts int64
		var lvl int
		var job, run, path sql.NullString
		var msg string
		if err := rows.Scan(&ts, &lvl, &job, &run, &msg, &path); err != nil {
			return nil, err
		}
		out = append(out, model.LogLine{TS: fromMs(ts), Level: LevelName(lvl), JobID: strPtr(job), RunID: strPtr(run), Msg: msg, Path: strPtr(path)})
	}
	return out, rows.Err()
}

func escapeLike(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}
