package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// Folders whose local copy hasn't changed since their last successful upload
// are skipped: no listing of the cloud side, no comparing. A stamp records
// what the folder looked like when it finished syncing. Every folder still
// gets a full check at least this often, to catch changes made in the cloud.
const fullCheckEvery = 7 * 24 * time.Hour

// syncState is what the engine remembers about one upload job, kept in the
// daemon's data folder (never inside the synced folder itself).
type syncState struct {
	// Key changes when anything that decides what a run copies changes
	// (destination, delete policy, rules); old stamps are then dropped.
	Key     string                 `json:"key"`
	Folders map[string]folderStamp `json:"folders"`
}

type folderStamp struct {
	Stamp     string    `json:"stamp"`     // local tree fingerprint at sync time
	Files     int       `json:"files"`     // files in the folder then (for the deletion guard)
	SyncedAt  time.Time `json:"syncedAt"`  // when it last finished syncing
	CheckedAt time.Time `json:"checkedAt"` // last run that compared it with the cloud
}

// skipMemory applies to full upload runs that remember synced folders.
func skipMemory(spec RunSpec) bool {
	return spec.StateFile != "" && spec.Job.Direction == model.DirUpload && spec.Files == nil && !spec.DryRun && spec.Filter != nil
}

func stateKey(spec RunSpec) string {
	h := sha256.New()
	fmt.Fprintf(h, "%s|%s|%s|%s|%s", spec.Remote, spec.Job.RemotePath, spec.Job.LocalPath, spec.Job.DeletePolicy, spec.Filter.Signature())
	return hex.EncodeToString(h.Sum(nil))[:16]
}

func loadState(spec RunSpec) *syncState {
	st := &syncState{Key: stateKey(spec), Folders: map[string]folderStamp{}}
	b, err := os.ReadFile(spec.StateFile)
	if err != nil {
		return st
	}
	var old syncState
	if json.Unmarshal(b, &old) == nil && old.Key == st.Key && old.Folders != nil {
		st.Folders = old.Folders
	}
	return st
}

func (st *syncState) save(file string) error {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return err
	}
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

// folderPrint fingerprints a local folder: the newest modification time of
// any file or folder in it, the file count and the total size. Adding,
// editing, deleting, renaming or moving anything inside changes it (a
// delete or rename updates the parent folder's time). Excluded folders such
// as node_modules or .git are not walked. fresh reports a file younger than
// the job's minimum age, which the run will skip, so the folder isn't done.
func folderPrint(spec RunSpec, rel string, now time.Time) (stamp string, files int, fresh bool, err error) {
	root := filepath.Join(spec.Job.LocalPath, filepath.FromSlash(rel))
	var newest int64
	var size int64
	minAge := spec.Filter.MinAge()
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		r, _ := filepath.Rel(spec.Job.LocalPath, p)
		if d.IsDir() && p != root {
			if ex, _ := spec.Filter.ExcludesDir(filepath.ToSlash(r)); ex {
				return filepath.SkipDir
			}
		}
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		if t := info.ModTime().UnixNano(); t > newest {
			newest = t
		}
		if !d.IsDir() {
			files++
			size += info.Size()
			if minAge > 0 && now.Sub(info.ModTime()) < minAge {
				fresh = true
			}
		}
		return nil
	})
	return fmt.Sprintf("%d-%d-%d", newest, files, size), files, fresh, err
}
