package engine

import (
	"context"
	"os"
	"time"

	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/rc"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// ProgressInterval is the progress sampling period (4 Hz).
const ProgressInterval = 250 * time.Millisecond

// pollProgress samples the stats group at 4 Hz until the returned stop
// function is called.
func pollProgress(ctx context.Context, group string, fn ProgressFn) (stop func()) {
	if fn == nil {
		return func() {}
	}
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		t := time.NewTicker(ProgressInterval)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-t.C:
				out, err := accounting.StatsGroup(ctx, group).RemoteStats(false)
				if err == nil {
					fn(ProgressFromStats(out))
				}
			}
		}
	}()
	return func() {
		close(done)
		<-finished
	}
}

// ProgressFromStats converts rclone core/stats output.
func ProgressFromStats(out rc.Params) model.Progress {
	p := model.Progress{
		Bytes:        i64(out["bytes"]),
		TotalBytes:   i64(out["totalBytes"]),
		Files:        i64(out["transfers"]),
		TotalFiles:   i64(out["totalTransfers"]),
		Speed:        f64(out["speed"]),
		Checks:       i64(out["checks"]),
		TotalChecks:  i64(out["totalChecks"]),
		Errors:       i64(out["errors"]),
		Transferring: []model.Transfer{},
	}
	if e, ok := out["eta"].(float64); ok {
		p.ETA = &e
	}
	if p.TotalBytes > 0 {
		p.Percent = float64(p.Bytes) * 100 / float64(p.TotalBytes)
		if p.Percent > 100 {
			p.Percent = 100
		}
	}
	if tr, ok := out["transferring"].([]rc.Params); ok {
		for _, t := range tr {
			x := model.Transfer{Name: str(t["name"]), Size: i64(t["size"]), Bytes: i64(t["bytes"]), Speed: f64(t["speed"])}
			if x.Size > 0 {
				x.Percent = float64(x.Bytes) * 100 / float64(x.Size)
			}
			p.Transferring = append(p.Transferring, x)
		}
	}
	return p
}

func i64(v any) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int:
		return int64(x)
	case float64:
		return int64(x)
	}
	return 0
}

func f64(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int64:
		return float64(x)
	case int:
		return float64(x)
	}
	return 0
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func readDirNames(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	return f.Readdirnames(-1)
}
