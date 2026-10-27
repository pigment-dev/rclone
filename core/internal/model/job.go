// Package model holds the wire types shared by the daemon, the CLI and the
// IPC protocol (docs/PROTOCOL.md). Field names are part of the contract.
package model

import "time"

// Directions.
const (
	DirUpload   = "upload"
	DirDownload = "download"
	DirTwoWay   = "twoWay"
)

// Delete policies.
const (
	DeleteMirror  = "mirror"
	DeleteArchive = "archive"
	DeleteNever   = "never"
)

// Conflict policies.
const (
	ConflictNewer        = "newer"
	ConflictKeepBoth     = "keepBoth"
	ConflictPreferLocal  = "preferLocal"
	ConflictPreferRemote = "preferRemote"
	ConflictAsk          = "ask"
)

// Job states.
const (
	StateIdle          = "idle"
	StateQueued        = "queued"
	StateRunning       = "running"
	StatePaused        = "paused"
	StateWaiting       = "waiting"
	StateError         = "error"
	StateNeedsBaseline = "needsBaseline"
)

// Job is a sync job definition plus its live status.
type Job struct {
	ID                   string       `json:"id"`
	Name                 string       `json:"name"`
	Enabled              bool         `json:"enabled"`
	LocalPath            string       `json:"localPath"`
	AccountID            string       `json:"accountId"`
	RemotePath           string       `json:"remotePath"`
	Direction            string       `json:"direction"`
	DeletePolicy         string       `json:"deletePolicy"`
	ArchiveRetentionDays int          `json:"archiveRetentionDays"`
	ConflictPolicy       string       `json:"conflictPolicy"`
	Filters              Filters      `json:"filters"`
	Triggers             Triggers     `json:"triggers"`
	Network              NetworkRules `json:"network"`
	Limits               Limits       `json:"limits"`
	Safety               Safety       `json:"safety"`
	CreatedAt            time.Time    `json:"createdAt"`
	UpdatedAt            time.Time    `json:"updatedAt"`
	Status               *JobStatus   `json:"status,omitempty"`
}

// Rule is a single custom filter rule.
type Rule struct {
	Kind    string `json:"kind"` // exclude|include
	Pattern string `json:"pattern"`
}

// Filters configures what a job syncs.
type Filters struct {
	Presets          []string `json:"presets"`
	Rules            []Rule   `json:"rules"`
	MaxSizeMB        *int     `json:"maxSizeMB"`
	MinAgeSec        int      `json:"minAgeSec"`
	ExcludeIfPresent []string `json:"excludeIfPresent"`
	RespectGitignore bool     `json:"respectGitignore"`
	SkipSymlinks     bool     `json:"skipSymlinks"`
}

// Weekly is a day-of-week (1=Monday..7=Sunday) plus HH:MM.
type Weekly struct {
	Day  int    `json:"day"`
	Time string `json:"time"`
}

// Triggers says when a job runs.
type Triggers struct {
	OnChange    bool    `json:"onChange"`
	DebounceSec int     `json:"debounceSec"`
	IntervalMin *int    `json:"intervalMin"`
	Daily       *string `json:"daily"`
	Weekly      *Weekly `json:"weekly"`
	Cron        *string `json:"cron"`
	OnWake      bool    `json:"onWake"`
	Manual      bool    `json:"manual"`
}

// NetworkRules restricts when a job may run.
type NetworkRules struct {
	AllowCellular     bool     `json:"allowCellular"`
	AllowExpensive    bool     `json:"allowExpensive"`
	WifiOnly          bool     `json:"wifiOnly"`
	SSIDAllow         []string `json:"ssidAllow"`
	SSIDDeny          []string `json:"ssidDeny"`
	PauseOnBattery    bool     `json:"pauseOnBattery"`
	MinBatteryPercent *int     `json:"minBatteryPercent"`
}

// Limits are per-job performance limits.
type Limits struct {
	BwUpKBps   *int `json:"bwUpKBps"`
	BwDownKBps *int `json:"bwDownKBps"`
	Transfers  int  `json:"transfers"`
	Checkers   int  `json:"checkers"`
}

// Safety holds data-loss guards.
type Safety struct {
	MaxDeletePercent int  `json:"maxDeletePercent"`
	DryRunFirst      bool `json:"dryRunFirst"`
	Checksum         bool `json:"checksum"`
}

// JobStatus is the live state of a job.
type JobStatus struct {
	State    string      `json:"state"`
	Reason   *string     `json:"reason"`
	LastRun  *RunSummary `json:"lastRun"`
	NextRun  *time.Time  `json:"nextRun"`
	Progress *Progress   `json:"progress"`
}

// RunSummary describes a finished (or running) run.
type RunSummary struct {
	ID        string     `json:"id"`
	StartedAt time.Time  `json:"startedAt"`
	EndedAt   *time.Time `json:"endedAt"`
	OK        bool       `json:"ok"`
	Error     *string    `json:"error"`
	Bytes     int64      `json:"bytes"`
	Files     int64      `json:"files"`
	Deletes   int64      `json:"deletes"`
	Conflicts int64      `json:"conflicts"`
	DryRun    bool       `json:"dryRun"`
}

// Transfer is one in-flight file.
type Transfer struct {
	Name    string  `json:"name"`
	Size    int64   `json:"size"`
	Bytes   int64   `json:"bytes"`
	Percent float64 `json:"percent"`
	Speed   float64 `json:"speed"`
}

// Progress is a snapshot of a running job.
type Progress struct {
	Bytes        int64      `json:"bytes"`
	TotalBytes   int64      `json:"totalBytes"`
	Files        int64      `json:"files"`
	TotalFiles   int64      `json:"totalFiles"`
	Speed        float64    `json:"speed"`
	ETA          *float64   `json:"eta"`
	Percent      float64    `json:"percent"`
	Checks       int64      `json:"checks"`
	TotalChecks  int64      `json:"totalChecks"`
	Errors       int64      `json:"errors"`
	Transferring []Transfer `json:"transferring"`
	// Large jobs run folder by folder: which part is running now.
	Phase string `json:"phase,omitempty"`
	Step  int    `json:"step,omitempty"`
	Steps int    `json:"steps,omitempty"`
}

// OverallProgress aggregates all running jobs.
type OverallProgress struct {
	Running    int      `json:"running"`
	Bytes      int64    `json:"bytes"`
	TotalBytes int64    `json:"totalBytes"`
	Percent    float64  `json:"percent"`
	Speed      float64  `json:"speed"`
	ETA        *float64 `json:"eta"`
}

// Excluded is a path the filters rejected and the rule responsible.
type Excluded struct {
	Path string `json:"path"`
	Rule string `json:"rule"`
}

// PreviewSample lists example paths per category.
type PreviewSample struct {
	Adds     []string   `json:"adds"`
	Updates  []string   `json:"updates"`
	Deletes  []string   `json:"deletes"`
	Excluded []Excluded `json:"excluded"`
}

// Preview is the result of jobs.preview.
type Preview struct {
	Adds     int           `json:"adds"`
	Updates  int           `json:"updates"`
	Deletes  int           `json:"deletes"`
	Excluded int           `json:"excluded"`
	Bytes    int64         `json:"bytes"`
	Sample   PreviewSample `json:"sample"`
}

// Ptr returns a pointer to v.
func Ptr[T any](v T) *T { return &v }
