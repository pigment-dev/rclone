// Package diag writes log exports and redacted diagnostics bundles.
package diag

import (
	"archive/zip"
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/store"
)

// WriteLogs writes lines (oldest first) as text or JSON lines.
func WriteLogs(dest, format string, lines []model.LogLine) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	if err := writeLogs(w, format, lines); err != nil {
		_ = f.Close()
		return err
	}
	if err := w.Flush(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func writeLogs(w io.Writer, format string, lines []model.LogLine) error {
	enc := json.NewEncoder(w)
	for _, l := range lines {
		l.Msg = store.Redact(l.Msg)
		if format == "json" {
			if err := enc.Encode(l); err != nil {
				return err
			}
			continue
		}
		job := "-"
		if l.JobID != nil {
			job = *l.JobID
		}
		path := ""
		if l.Path != nil {
			path = *l.Path + ": "
		}
		if _, err := fmt.Fprintf(w, "%s %-6s [%s] %s%s\n", l.TS.Format(time.RFC3339), l.Level, job, path, l.Msg); err != nil {
			return err
		}
	}
	return nil
}

// Input is everything placed in a bundle. None of it contains secrets:
// credentials live only in the encrypted rclone.conf, which is excluded.
type Input struct {
	Info     map[string]any
	Settings model.Settings
	Jobs     []model.Job
	Accounts []model.Account
	Actions  []model.Action
	Logs     []model.LogLine
}

// Bundle writes a zip for bug reports.
func Bundle(dest string, in Input) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	zw := zip.NewWriter(f)
	add := func(name string, v any) error {
		w, err := zw.Create(name)
		if err != nil {
			return err
		}
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	in.Info["goVersion"] = runtime.Version()
	in.Info["bundleCreatedAt"] = time.Now().UTC()
	for _, a := range in.Actions {
		a.Message = store.Redact(a.Message)
	}
	steps := []struct {
		name string
		v    any
	}{{"info.json", in.Info}, {"settings.json", in.Settings}, {"jobs.json", in.Jobs}, {"accounts.json", in.Accounts}, {"actions.json", in.Actions}}
	for _, s := range steps {
		if err := add(s.name, s.v); err != nil {
			_ = f.Close()
			return err
		}
	}
	w, err := zw.Create("logs.txt")
	if err == nil {
		err = writeLogs(w, "text", in.Logs)
	}
	if err != nil {
		_ = f.Close()
		return err
	}
	if err := zw.Close(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
