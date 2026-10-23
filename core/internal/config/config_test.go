package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/pigment-dev/rclone/core/internal/model"
)

func TestRoundTripAndAtomic(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	j := NewJobDefaults(s.Settings())
	j.ID, j.Name = "job_a", "A"
	if err := s.PutJob(j); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateRuntime("job_a", func(r *JobRuntime) { r.Paused = true }); err != nil {
		t.Fatal(err)
	}
	if err := s.PutAccount(model.Account{ID: "acc_1", Provider: "s3", Name: "B"}); err != nil {
		t.Fatal(err)
	}
	st := s.Settings()
	st.Logs.Level = "debug"
	if err := s.PutSettings(st); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, "jobs.json"))
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Errorf("jobs.json mode %v, want 0600", fi.Mode().Perm())
	}
	tmp, _ := filepath.Glob(filepath.Join(dir, ".*.tmp*"))
	if len(tmp) > 0 {
		t.Errorf("temp files left behind: %v", tmp)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "jobs.json"))
	if !strings.Contains(string(raw), `"version": 1`) {
		t.Error("schema version missing")
	}
	s2, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := s2.Job("job_a"); !ok || got.Name != "A" {
		t.Error("job not persisted")
	}
	if !s2.Runtime("job_a").Paused {
		t.Error("runtime not persisted")
	}
	if s2.Settings().Logs.Level != "debug" || len(s2.Accounts()) != 1 {
		t.Error("settings/accounts not persisted")
	}
}

func TestMigrateV0AndFuture(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "jobs.json"), []byte(`{"jobs":[{"id":"job_old","name":"Old"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	j, ok := s.Job("job_old")
	if !ok || j.Direction != model.DirUpload || j.Limits.Transfers != 4 {
		t.Errorf("v0 job not migrated/normalised: %+v", j)
	}
	if err := os.WriteFile(filepath.Join(dir, "jobs.json"), []byte(`{"version":99,"jobs":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(dir); err == nil {
		t.Error("newer schema must be refused")
	}
}

func TestMergePatchNulls(t *testing.T) {
	j := NewJobDefaults(DefaultSettings())
	j.Triggers.IntervalMin = model.Ptr(15)
	j.Name = "x"
	if err := MergePatch(&j, json.RawMessage(`{"name":"y","triggers":{"intervalMin":null,"daily":"08:00"}}`)); err != nil {
		t.Fatal(err)
	}
	if j.Name != "y" || j.Triggers.IntervalMin != nil || j.Triggers.Daily == nil || *j.Triggers.Daily != "08:00" {
		t.Errorf("bad merge: %+v", j.Triggers)
	}
	if j.Limits.Transfers != 4 {
		t.Error("untouched fields must survive")
	}
}

func TestValidate(t *testing.T) {
	dir := t.TempDir()
	j := NewJobDefaults(DefaultSettings())
	j.Name, j.LocalPath, j.AccountID = "ok", dir, "acc_1"
	exists := func(id string) bool { return id == "acc_1" }
	if err := Validate(&j, exists); err != nil {
		t.Fatal(err)
	}
	bad := []func(*model.Job){
		func(j *model.Job) { j.LocalPath = "relative/path" },
		func(j *model.Job) { j.AccountID = "acc_missing" },
		func(j *model.Job) { j.Direction = "sideways" },
		func(j *model.Job) { j.Filters.Presets = []string{"nope"} },
		func(j *model.Job) { j.Triggers.Cron = model.Ptr("bad") },
		func(j *model.Job) { j.Filters.Rules = []model.Rule{{Kind: "maybe", Pattern: "x"}} },
	}
	for i, mod := range bad {
		c := j
		mod(&c)
		if Validate(&c, exists) == nil {
			t.Errorf("case %d accepted", i)
		}
	}
}
