// Package engine runs syncs. Rclone embeds rclone in-process; the
// interface lets demo mode substitute a simulator.
package engine

import (
	"context"
	"errors"
	"time"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/policy"
)

// RunSpec is everything needed to execute one run of a job.
type RunSpec struct {
	RunID   string
	Job     model.Job
	Remote  string // rclone remote name of the account, e.g. "pd_acc_x1"
	Filter  *filters.Compiled
	WorkDir string // bisync workdir for this job
	DryRun  bool
	Resync  bool
	Force   bool     // bypass the max-delete guard (user chose "run anyway")
	Files   []string // upload fast path: only these relative paths
	Now     time.Time
}

// Conflict is a two-way conflict where both copies were kept.
type Conflict struct {
	Path       string `json:"path"`       // original relative path
	LocalCopy  string `json:"localCopy"`  // relative path of the local version
	RemoteCopy string `json:"remoteCopy"` // relative path of the remote version
}

// Failure kinds of a run.
const (
	FailNone        = ""
	FailMaxDelete   = "maxDelete"
	FailAuth        = "auth"
	FailQuota       = "quota"
	FailPermission  = "permission"
	FailNeedsResync = "needsResync"
	FailPathTooLong = "pathTooLong"
	FailCancelled   = "cancelled"
	FailOther       = "error"
)

// RunResult is the outcome of a run.
type RunResult struct {
	Bytes     int64
	Files     int64
	Deletes   int64
	Conflicts []Conflict
	Err       error
	Fail      string
}

// ProgressFn receives progress snapshots (about 4 Hz).
type ProgressFn func(model.Progress)

// LogFn receives log lines produced by the engine.
type LogFn func(model.LogLine)

// Engine abstracts the sync backend.
type Engine interface {
	Run(ctx context.Context, spec RunSpec, progress ProgressFn) RunResult
	Preview(ctx context.Context, spec RunSpec) (*model.Preview, error)
	List(ctx context.Context, remote, path string, dirsOnly bool) ([]model.Entry, error)
	Mkdir(ctx context.Context, remote, path string) error
	About(ctx context.Context, remote string) (*model.Quota, error)
	Identity(ctx context.Context, remote string) (*model.Identity, error)
	Test(ctx context.Context, remote string) (time.Duration, error)
	DeleteRemote(remote string)
	SetBandwidth(l policy.Limit) error
	ResolveConflict(ctx context.Context, job model.Job, c Conflict, choice string) error
	DedupeScan(ctx context.Context, remote, path string) ([]DupGroup, error)
	DedupeApply(ctx context.Context, remote, path, mode string) (removed, renamed int, err error)
	RcloneVersion() string
	SetLogSink(fn LogFn)
}

// DupFile is one file in a duplicate group.
type DupFile struct {
	ID      string    `json:"id"`
	Path    string    `json:"path"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
}

// DupGroup is a set of same-name files.
type DupGroup struct {
	Name  string    `json:"name"`
	Files []DupFile `json:"files"`
}

// ErrUnsupported is returned when a backend lacks a feature.
var ErrUnsupported = errors.New("not supported by this storage provider")
