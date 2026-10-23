// Package store keeps runs, log lines and Action Center items in SQLite
// (pure-Go modernc driver, no cgo).
package store

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver

	"github.com/pigment-dev/rclone/core/internal/model"
)

const schema = `
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY, job_id TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER,
  ok INTEGER NOT NULL DEFAULT 0, error TEXT, bytes INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0,
  deletes INTEGER NOT NULL DEFAULT 0, conflicts INTEGER NOT NULL DEFAULT 0, dry_run INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS runs_job ON runs(job_id, started_at DESC);
CREATE TABLE IF NOT EXISTS logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, level INTEGER NOT NULL,
  job_id TEXT, run_id TEXT, msg TEXT NOT NULL, path TEXT);
CREATE INDEX IF NOT EXISTS logs_ts ON logs(ts DESC);
CREATE INDEX IF NOT EXISTS logs_job_ts ON logs(job_id, ts DESC);
CREATE TABLE IF NOT EXISTS actions (
  id TEXT PRIMARY KEY, job_id TEXT, kind TEXT NOT NULL, severity TEXT NOT NULL, title TEXT NOT NULL,
  message TEXT NOT NULL, path TEXT, created_at INTEGER NOT NULL, resolved INTEGER NOT NULL DEFAULT 0,
  choices TEXT NOT NULL DEFAULT '[]', data TEXT NOT NULL DEFAULT '{}');
CREATE INDEX IF NOT EXISTS actions_open ON actions(resolved, created_at DESC);
`

// Store is the SQLite-backed history store.
type Store struct {
	db *sql.DB

	mu      sync.Mutex
	pending []model.LogLine
	flushCh chan struct{}
	done    chan struct{}
	wg      sync.WaitGroup
}

// Open opens (creating) the database in dir.
func Open(dir string) (*Store, error) {
	p := filepath.Join(dir, "pdrclone.db")
	q := url.Values{}
	for _, pr := range []string{"journal_mode(WAL)", "busy_timeout(5000)", "synchronous(NORMAL)", "cache_size(-2000)", "foreign_keys(ON)"} {
		q.Add("_pragma", pr)
	}
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(p)+"?"+q.Encode())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one writer; keeps memory low and avoids SQLITE_BUSY
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("init schema: %w", err)
	}
	s := &Store{db: db, flushCh: make(chan struct{}, 1), done: make(chan struct{})}
	s.wg.Add(1)
	go s.flusher()
	return s, nil
}

// Close flushes pending logs and closes the database.
func (s *Store) Close() error {
	close(s.done)
	s.wg.Wait()
	return s.db.Close()
}

func ms(t time.Time) int64 { return t.UTC().UnixMilli() }

func fromMs(v int64) time.Time { return time.UnixMilli(v).UTC() }

func nullStr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func strPtr(ns sql.NullString) *string {
	if !ns.Valid {
		return nil
	}
	s := ns.String
	return &s
}

// Prune deletes logs older than retention and resolved actions / runs
// older than 4x retention.
func (s *Store) Prune(ctx context.Context, retention time.Duration) error {
	cut := ms(time.Now().Add(-retention))
	if _, err := s.db.ExecContext(ctx, `DELETE FROM logs WHERE ts < ?`, cut); err != nil {
		return err
	}
	old := ms(time.Now().Add(-4 * retention))
	if _, err := s.db.ExecContext(ctx, `DELETE FROM actions WHERE resolved = 1 AND created_at < ?`, old); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM runs WHERE started_at < ?`, old)
	return err
}
