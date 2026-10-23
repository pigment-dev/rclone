package config

import (
	"path/filepath"
	"sync"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// JobRuntime is daemon-private per-job state that survives restarts.
type JobRuntime struct {
	Paused            bool   `json:"paused,omitempty"`
	NeedsBaseline     bool   `json:"needsBaseline,omitempty"`
	PreviewDone       bool   `json:"previewDone,omitempty"`
	LastFullReconcile string `json:"lastFullReconcile,omitempty"`
}

type jobsFile struct {
	Version int                    `json:"version"`
	Jobs    []model.Job            `json:"jobs"`
	Runtime map[string]*JobRuntime `json:"runtime"`
}

type accountsFile struct {
	Version  int             `json:"version"`
	Accounts []model.Account `json:"accounts"`
}

type settingsFile struct {
	Version  int            `json:"version"`
	Settings model.Settings `json:"settings"`
}

// Store is the in-memory, mutex-guarded copy of the config files.
type Store struct {
	dir string
	mu  sync.Mutex

	jobs     []model.Job
	runtime  map[string]*JobRuntime
	accounts []model.Account
	settings model.Settings
}

// Open loads (or initialises) the config files in dir.
func Open(dir string) (*Store, error) {
	s := &Store{dir: dir, runtime: map[string]*JobRuntime{}, settings: DefaultSettings()}
	var jf jobsFile
	if ok, err := readVersioned(s.path("jobs.json"), &jf, migrateV0); err != nil {
		return nil, err
	} else if ok {
		s.jobs = jf.Jobs
		if jf.Runtime != nil {
			s.runtime = jf.Runtime
		}
	}
	var af accountsFile
	if ok, err := readVersioned(s.path("accounts.json"), &af, migrateV0); err != nil {
		return nil, err
	} else if ok {
		s.accounts = af.Accounts
	}
	var sf settingsFile
	sf.Settings = DefaultSettings()
	if ok, err := readVersioned(s.path("settings.json"), &sf, migrateV0); err != nil {
		return nil, err
	} else if ok {
		s.settings = sf.Settings
	}
	for i := range s.jobs {
		s.jobs[i].Status = nil
		Normalize(&s.jobs[i], s.settings)
	}
	return s, nil
}

// Dir returns the config directory.
func (s *Store) Dir() string { return s.dir }

func (s *Store) path(name string) string { return filepath.Join(s.dir, name) }

// Jobs returns a copy of all jobs (without status).
func (s *Store) Jobs() []model.Job {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]model.Job(nil), s.jobs...)
}

// Job returns one job.
func (s *Store) Job(id string) (model.Job, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.jobs {
		if j.ID == id {
			return j, true
		}
	}
	return model.Job{}, false
}

// PutJob inserts or replaces a job and saves.
func (s *Store) PutJob(j model.Job) error {
	j.Status = nil
	s.mu.Lock()
	defer s.mu.Unlock()
	replaced := false
	for i := range s.jobs {
		if s.jobs[i].ID == j.ID {
			s.jobs[i] = j
			replaced = true
		}
	}
	if !replaced {
		s.jobs = append(s.jobs, j)
	}
	return s.saveJobsLocked()
}

// DeleteJob removes a job and its runtime state.
func (s *Store) DeleteJob(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.jobs[:0]
	for _, j := range s.jobs {
		if j.ID != id {
			out = append(out, j)
		}
	}
	s.jobs = out
	delete(s.runtime, id)
	return s.saveJobsLocked()
}

// Runtime returns a copy of the job's runtime state.
func (s *Store) Runtime(id string) JobRuntime {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r := s.runtime[id]; r != nil {
		return *r
	}
	return JobRuntime{}
}

// UpdateRuntime mutates the runtime state of a job and saves.
func (s *Store) UpdateRuntime(id string, fn func(*JobRuntime)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.runtime[id]
	if r == nil {
		r = &JobRuntime{}
		s.runtime[id] = r
	}
	fn(r)
	return s.saveJobsLocked()
}

func (s *Store) saveJobsLocked() error {
	return WriteJSON(s.path("jobs.json"), jobsFile{Version: SchemaVersion, Jobs: s.jobs, Runtime: s.runtime})
}

// Accounts returns a copy of all accounts.
func (s *Store) Accounts() []model.Account {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]model.Account(nil), s.accounts...)
}

// Account returns one account.
func (s *Store) Account(id string) (model.Account, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, a := range s.accounts {
		if a.ID == id {
			return a, true
		}
	}
	return model.Account{}, false
}

// PutAccount inserts or replaces an account and saves.
func (s *Store) PutAccount(a model.Account) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	replaced := false
	for i := range s.accounts {
		if s.accounts[i].ID == a.ID {
			s.accounts[i] = a
			replaced = true
		}
	}
	if !replaced {
		s.accounts = append(s.accounts, a)
	}
	return WriteJSON(s.path("accounts.json"), accountsFile{Version: SchemaVersion, Accounts: s.accounts})
}

// DeleteAccount removes an account and saves.
func (s *Store) DeleteAccount(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.accounts[:0]
	for _, a := range s.accounts {
		if a.ID != id {
			out = append(out, a)
		}
	}
	s.accounts = out
	return WriteJSON(s.path("accounts.json"), accountsFile{Version: SchemaVersion, Accounts: s.accounts})
}

// Settings returns the current settings.
func (s *Store) Settings() model.Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	return cloneSettings(s.settings)
}

// PutSettings replaces settings and saves.
func (s *Store) PutSettings(st model.Settings) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.settings = cloneSettings(st)
	return WriteJSON(s.path("settings.json"), settingsFile{Version: SchemaVersion, Settings: s.settings})
}

func cloneSettings(st model.Settings) model.Settings {
	st.Defaults.Presets = append([]string(nil), st.Defaults.Presets...)
	st.Network.BwSchedule = append([]model.BwWindow(nil), st.Network.BwSchedule...)
	return st
}
