package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/sched"
)

// DefaultSettings returns factory settings.
func DefaultSettings() model.Settings {
	var s model.Settings
	s.Defaults.Direction = model.DirUpload
	s.Defaults.ConflictPolicy = model.ConflictNewer
	s.Defaults.DeletePolicy = model.DeleteArchive
	s.Defaults.DebounceSec = 10
	s.Defaults.MinAgeSec = 5
	s.Defaults.MaxDeletePercent = 25
	s.Defaults.DryRunFirst = true
	s.Defaults.Presets = []string{"vcs", "ide", "deps", "osjunk"}
	s.Network.AllowCellular = false
	s.Network.AllowExpensive = true
	s.Network.BwSchedule = []model.BwWindow{}
	s.Logs.Level = "info"
	s.Logs.RetentionDays = 30
	s.Engine.Transfers = 4
	s.Engine.Checkers = 8
	s.Engine.MemoryLimitMB = 256
	return s
}

// Normalize fills zero values of a job with defaults from settings.
func Normalize(j *model.Job, st model.Settings) {
	if j.Direction == "" {
		j.Direction = st.Defaults.Direction
	}
	if j.DeletePolicy == "" {
		j.DeletePolicy = st.Defaults.DeletePolicy
	}
	if j.ConflictPolicy == "" {
		j.ConflictPolicy = st.Defaults.ConflictPolicy
	}
	if j.ArchiveRetentionDays == 0 {
		j.ArchiveRetentionDays = 30
	}
	if j.Filters.Presets == nil {
		j.Filters.Presets = append([]string(nil), st.Defaults.Presets...)
	}
	if j.Filters.Rules == nil {
		j.Filters.Rules = []model.Rule{}
	}
	if j.Filters.ExcludeIfPresent == nil {
		j.Filters.ExcludeIfPresent = []string{".nosync"}
	}
	if j.Triggers.DebounceSec <= 0 {
		j.Triggers.DebounceSec = st.Defaults.DebounceSec
	}
	if j.Network.SSIDAllow == nil {
		j.Network.SSIDAllow = []string{}
	}
	if j.Network.SSIDDeny == nil {
		j.Network.SSIDDeny = []string{}
	}
	if j.Limits.Transfers <= 0 {
		j.Limits.Transfers = st.Engine.Transfers
	}
	if j.Limits.Checkers <= 0 {
		j.Limits.Checkers = st.Engine.Checkers
	}
	if j.Safety.MaxDeletePercent <= 0 {
		j.Safety.MaxDeletePercent = st.Defaults.MaxDeletePercent
	}
}

// NewJobDefaults returns the defaults applied to jobs.create before the
// client payload is merged on top.
func NewJobDefaults(st model.Settings) model.Job {
	j := model.Job{Enabled: true}
	j.Triggers.Manual = true
	j.Filters.MinAgeSec = st.Defaults.MinAgeSec
	j.Safety.DryRunFirst = st.Defaults.DryRunFirst
	j.Network.AllowCellular = st.Network.AllowCellular
	j.Network.AllowExpensive = st.Network.AllowExpensive
	Normalize(&j, st)
	return j
}

// Validate checks a job definition. accountExists reports whether an
// account id is configured.
func Validate(j *model.Job, accountExists func(string) bool) error {
	if j.Name == "" {
		return errors.New("name is required")
	}
	if !filepath.IsAbs(j.LocalPath) {
		return fmt.Errorf("localPath must be absolute: %q", j.LocalPath)
	}
	if fi, err := os.Stat(j.LocalPath); err != nil {
		if !(j.Direction == model.DirDownload && errors.Is(err, os.ErrNotExist)) {
			return fmt.Errorf("localPath: %w", err)
		}
	} else if !fi.IsDir() {
		return fmt.Errorf("localPath is not a directory: %q", j.LocalPath)
	}
	if !accountExists(j.AccountID) {
		return fmt.Errorf("account %q not found", j.AccountID)
	}
	if !slices.Contains([]string{model.DirUpload, model.DirDownload, model.DirTwoWay}, j.Direction) {
		return fmt.Errorf("invalid direction %q", j.Direction)
	}
	if !slices.Contains([]string{model.DeleteMirror, model.DeleteArchive, model.DeleteNever}, j.DeletePolicy) {
		return fmt.Errorf("invalid deletePolicy %q", j.DeletePolicy)
	}
	if !slices.Contains([]string{model.ConflictNewer, model.ConflictKeepBoth, model.ConflictPreferLocal, model.ConflictPreferRemote, model.ConflictAsk}, j.ConflictPolicy) {
		return fmt.Errorf("invalid conflictPolicy %q", j.ConflictPolicy)
	}
	if j.Safety.MaxDeletePercent < 0 || j.Safety.MaxDeletePercent > 100 {
		return errors.New("safety.maxDeletePercent must be 0-100")
	}
	for _, p := range j.Filters.Presets {
		if !filters.IsPreset(p) {
			return fmt.Errorf("unknown filter preset %q", p)
		}
	}
	for _, r := range j.Filters.Rules {
		if r.Kind != "include" && r.Kind != "exclude" {
			return fmt.Errorf("invalid rule kind %q", r.Kind)
		}
		if r.Pattern == "" {
			return errors.New("empty filter pattern")
		}
	}
	if err := sched.ValidateTriggers(j.Triggers); err != nil {
		return err
	}
	return nil
}

// MergePatch applies an RFC 7386 JSON merge patch to v (a struct pointer).
func MergePatch(v any, patch json.RawMessage) error {
	orig, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var target any
	if err := json.Unmarshal(orig, &target); err != nil {
		return err
	}
	var p any
	if err := json.Unmarshal(patch, &p); err != nil {
		return err
	}
	merged, err := json.Marshal(mergeValue(target, p))
	if err != nil {
		return err
	}
	// Reset first so keys removed by a null in the patch become zero values.
	rv := reflect.ValueOf(v).Elem()
	rv.Set(reflect.Zero(rv.Type()))
	return json.Unmarshal(merged, v)
}

func mergeValue(target, patch any) any {
	pm, ok := patch.(map[string]any)
	if !ok {
		return patch
	}
	tm, ok := target.(map[string]any)
	if !ok {
		tm = map[string]any{}
	}
	for k, pv := range pm {
		if pv == nil {
			delete(tm, k)
			continue
		}
		tm[k] = mergeValue(tm[k], pv)
	}
	return tm
}
