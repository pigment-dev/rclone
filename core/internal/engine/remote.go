package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	rfs "github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/operations"
	"github.com/rclone/rclone/fs/walk"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

// fsFor returns the fs string: remote "" means the local filesystem.
func fsFor(remote, p string) string {
	if remote == "" {
		if p == "" {
			p = "/"
		}
		return p
	}
	return RemoteFs(remote, p)
}

// Google Drive "Computers" (folders backed up by Drive for desktop) live
// outside My Drive. They are addressed with virtual paths:
//
//	@computers                      the list of computers
//	@computer:<folderID>:<name>/sub  a folder inside one computer
//
// RemoteFs turns the second form into remote,root_folder_id=<folderID>:sub.
const (
	ComputersPath   = "@computers"
	computerPrefix  = "@computer:"
	driveFolderMime = "application/vnd.google-apps.folder"
)

// ParseComputerPath splits a "@computer:<id>:<name>/sub" path.
func ParseComputerPath(p string) (id, sub string, ok bool) {
	rest, found := strings.CutPrefix(strings.TrimPrefix(p, "/"), computerPrefix)
	if !found {
		return "", "", false
	}
	id, after, found := strings.Cut(rest, ":")
	if !found || id == "" {
		return "", "", false
	}
	_, sub, _ = strings.Cut(after, "/")
	return id, sub, true
}

func isDrive(remote string) bool {
	t, _ := config.FileGetValue(remote, "type")
	return t == "drive"
}

// computers lists the Drive for desktop "Computers" roots: folders owned by
// the user that have no parent. Drive can't query "no parent" directly, so
// this pages through the user's folders with a minimal field set (much faster
// than a full rclone listing) and caches the answer for ten minutes.
func (r *Rclone) computers(ctx context.Context, remote string) ([]model.Entry, error) {
	r.mu.Lock()
	if c, ok := r.computerCache[remote]; ok && time.Since(c.at) < 10*time.Minute {
		r.mu.Unlock()
		return c.entries, nil
	}
	r.mu.Unlock()
	token, err := r.accessToken(ctx, remote)
	if err != nil {
		return nil, err
	}
	q := "'me' in owners and mimeType='" + driveFolderMime + "' and trashed=false and not 'root' in parents"
	out := []model.Entry{}
	page := ""
	for {
		v := url.Values{}
		v.Set("q", q)
		v.Set("fields", "nextPageToken,files(id,name,parents,modifiedTime)")
		v.Set("pageSize", "1000")
		v.Set("spaces", "drive")
		if page != "" {
			v.Set("pageToken", page)
		}
		req, err := http.NewRequestWithContext(ctx, "GET", "https://www.googleapis.com/drive/v3/files?"+v.Encode(), nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		var body struct {
			NextPageToken string `json:"nextPageToken"`
			Files         []struct {
				ID, Name, ModifiedTime string
				Parents                []string
			} `json:"files"`
		}
		err = json.NewDecoder(resp.Body).Decode(&body)
		_ = resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			return nil, fmt.Errorf("google drive: HTTP %d", resp.StatusCode)
		}
		if err != nil {
			return nil, err
		}
		for _, fl := range body.Files {
			if len(fl.Parents) != 0 || fl.ID == "" {
				continue
			}
			mt, _ := time.Parse(time.RFC3339, fl.ModifiedTime)
			name := strings.ReplaceAll(fl.Name, "/", "-")
			out = append(out, model.Entry{Name: fl.Name, Path: computerPrefix + fl.ID + ":" + name, IsDir: true, ModTime: mt.UTC()})
		}
		if body.NextPageToken == "" {
			break
		}
		page = body.NextPageToken
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	r.mu.Lock()
	r.computerCache[remote] = computerList{at: time.Now(), entries: out}
	r.mu.Unlock()
	return out, nil
}

type computerList struct {
	at      time.Time
	entries []model.Entry
}

// List lists one directory level.
func (r *Rclone) List(ctx context.Context, remote, p string, dirsOnly bool) ([]model.Entry, error) {
	if remote != "" && p == ComputersPath {
		ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
		defer cancel()
		return r.computers(ctx, remote)
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	f, err := rfs.NewFs(ctx, fsFor(remote, p))
	if err != nil {
		return nil, err
	}
	entries, err := f.List(ctx, "")
	if err != nil {
		return nil, err
	}
	out := make([]model.Entry, 0, len(entries))
	for _, e := range entries {
		_, isDir := e.(rfs.Directory)
		if dirsOnly && !isDir {
			continue
		}
		name := path.Base(e.Remote())
		full := strings.TrimPrefix(path.Join(p, name), "/")
		if remote == "" {
			full = filepath.Join(p, name)
		}
		out = append(out, model.Entry{Name: name, Path: full, IsDir: isDir, Size: max(0, e.Size()), ModTime: e.ModTime(ctx).UTC()})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDir != out[j].IsDir {
			return out[i].IsDir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	if remote != "" && p == "" && isDrive(remote) {
		out = append([]model.Entry{{Name: "Computers", Path: ComputersPath, IsDir: true}}, out...)
	}
	return out, nil
}

// Mkdir creates a directory.
func (r *Rclone) Mkdir(ctx context.Context, remote, p string) error {
	if id, sub, ok := ParseComputerPath(p); ok {
		f, err := rfs.NewFs(ctx, RemoteFs(remote, computerPrefix+id+":x"))
		if err != nil {
			return err
		}
		return operations.Mkdir(ctx, f, strings.Trim(sub, "/"))
	}
	f, err := rfs.NewFs(ctx, fsFor(remote, ""))
	if err != nil {
		return err
	}
	return operations.Mkdir(ctx, f, strings.Trim(p, "/"))
}

// About returns the quota of a remote.
func (r *Rclone) About(ctx context.Context, remote string) (*model.Quota, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	f, err := rfs.NewFs(ctx, RemoteFs(remote, ""))
	if err != nil {
		return nil, err
	}
	about := f.Features().About
	if about == nil {
		return nil, ErrUnsupported
	}
	u, err := about(ctx)
	if err != nil {
		return nil, err
	}
	return &model.Quota{Total: u.Total, Used: u.Used, Free: u.Free, Trashed: u.Trashed}, nil
}

// Test lists the root of a remote with a timeout.
func (r *Rclone) Test(ctx context.Context, remote string) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	start := time.Now()
	f, err := rfs.NewFs(ctx, RemoteFs(remote, ""))
	if err != nil {
		return 0, err
	}
	if _, err := f.List(ctx, ""); err != nil && !errors.Is(err, rfs.ErrorDirNotFound) {
		return 0, err
	}
	return time.Since(start), nil
}

// ResolveConflict applies a conflict choice on the local side; the next
// two-way run propagates it to the remote.
func (r *Rclone) ResolveConflict(_ context.Context, job model.Job, c Conflict, choice string) error {
	abs := func(rel string) string { return filepath.Join(job.LocalPath, filepath.FromSlash(rel)) }
	keep, drop := "", ""
	switch choice {
	case "keepBoth", "dismiss":
		return nil
	case "keepLocal":
		keep, drop = c.LocalCopy, c.RemoteCopy
	case "keepRemote":
		keep, drop = c.RemoteCopy, c.LocalCopy
	default:
		return fmt.Errorf("unknown choice %q", choice)
	}
	if keep != "" && statLocal(abs(keep)) {
		if err := os.Rename(abs(keep), abs(c.Path)); err != nil {
			return err
		}
	}
	if drop != "" && statLocal(abs(drop)) {
		if err := os.Remove(abs(drop)); err != nil {
			return err
		}
	}
	return nil
}

// pruneArchives purges archive folders older than the retention period.
func (r *Rclone) pruneArchives(ctx context.Context, spec RunSpec) {
	if spec.Job.ArchiveRetentionDays <= 0 {
		return
	}
	cut := spec.Now.AddDate(0, 0, -spec.Job.ArchiveRetentionDays).Format("2006-01-02")
	var sides []string
	switch spec.Job.Direction {
	case model.DirUpload:
		sides = []string{RemoteFs(spec.Remote, spec.Job.RemotePath)}
	case model.DirDownload:
		sides = []string{spec.Job.LocalPath}
	default:
		sides = []string{spec.Job.LocalPath, RemoteFs(spec.Remote, spec.Job.RemotePath)}
	}
	ctx = accounting.WithStatsGroup(ctx, spec.RunID+"-prune")
	defer deleteStatsGroup(spec.RunID + "-prune")
	for _, s := range sides {
		f, err := rfs.NewFs(ctx, joinFs(s, filters.ArchiveDir))
		if err != nil {
			continue
		}
		entries, err := f.List(ctx, "")
		if err != nil {
			continue
		}
		for _, e := range entries {
			if _, ok := e.(rfs.Directory); ok && len(e.Remote()) == 10 && e.Remote() < cut {
				if err := operations.Purge(ctx, f, e.Remote()); err == nil {
					rfs.Infof(nil, "Pruned archive %s/%s", filters.ArchiveDir, e.Remote())
				}
			}
		}
	}
}

// DedupeScan finds same-path duplicates (Google Drive allows them).
func (r *Rclone) DedupeScan(ctx context.Context, remote, p string) ([]DupGroup, error) {
	f, err := rfs.NewFs(ctx, RemoteFs(remote, p))
	if err != nil {
		return nil, err
	}
	byName := map[string][]DupFile{}
	err = walk.ListR(ctx, f, "", true, -1, walk.ListObjects, func(entries rfs.DirEntries) error {
		for _, e := range entries {
			o, ok := e.(rfs.Object)
			if !ok {
				continue
			}
			df := DupFile{Path: o.Remote(), Size: o.Size(), ModTime: o.ModTime(ctx).UTC()}
			if ider, ok := o.(rfs.IDer); ok {
				df.ID = ider.ID()
			}
			byName[o.Remote()] = append(byName[o.Remote()], df)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	groups := []DupGroup{}
	for name, files := range byName {
		if len(files) > 1 {
			groups = append(groups, DupGroup{Name: name, Files: files})
		}
	}
	sort.Slice(groups, func(i, j int) bool { return groups[i].Name < groups[j].Name })
	return groups, nil
}

// DedupeApply resolves duplicates with mode newest|largest|rename.
func (r *Rclone) DedupeApply(ctx context.Context, remote, p, mode string) (int, int, error) {
	var m operations.DeduplicateMode
	switch mode {
	case "newest":
		m = operations.DeduplicateNewest
	case "largest":
		m = operations.DeduplicateLargest
	case "rename":
		m = operations.DeduplicateRename
	default:
		return 0, 0, fmt.Errorf("unknown mode %q", mode)
	}
	f, err := rfs.NewFs(ctx, RemoteFs(remote, p))
	if err != nil {
		return 0, 0, err
	}
	group := fmt.Sprintf("dedupe-%d", time.Now().UnixNano())
	ctx = accounting.WithStatsGroup(ctx, group)
	defer deleteStatsGroup(group)
	err = operations.Deduplicate(ctx, f, m, false)
	st := accounting.StatsGroup(ctx, group)
	return int(st.GetDeletes()), int(st.Renames(0)), err
}
