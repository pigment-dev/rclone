// Package config persists jobs, accounts and settings as versioned JSON
// files with atomic writes.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// SchemaVersion is the current on-disk schema version of every file.
const SchemaVersion = 1

// WriteJSON atomically writes v to path (temp file + fsync + rename), 0600.
func WriteJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(path, append(data, '\n'))
}

// WriteFileAtomic writes data to path atomically with mode 0600.
func WriteFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer func() { _ = os.Remove(tmp) }()
	if err := f.Chmod(0o600); err != nil && !errors.Is(err, errors.ErrUnsupported) {
		_ = f.Close()
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// envelope is the common on-disk wrapper used to detect the version.
type envelope struct {
	Version int `json:"version"`
}

// readVersioned reads path into out after checking/migrating the version.
// A missing file returns (false, nil).
func readVersioned(path string, out any, migrate func(from int, raw []byte) ([]byte, error)) (bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return false, fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	if env.Version > SchemaVersion {
		return false, fmt.Errorf("%s: schema version %d is newer than supported %d", filepath.Base(path), env.Version, SchemaVersion)
	}
	if env.Version < SchemaVersion && migrate != nil {
		if raw, err = migrate(env.Version, raw); err != nil {
			return false, fmt.Errorf("%s: migrate from v%d: %w", filepath.Base(path), env.Version, err)
		}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return false, fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	return true, nil
}

// migrateV0 handles files written before versioning (version 0/absent):
// the payload is identical, only the version field is added.
func migrateV0(_ int, raw []byte) ([]byte, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	m["version"] = json.RawMessage(fmt.Sprint(SchemaVersion))
	return json.Marshal(m)
}
