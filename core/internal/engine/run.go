package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rclone/rclone/cmd/bisync/bilib"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/filter"
	"github.com/rclone/rclone/fs/rc"
	"github.com/rclone/rclone/fs/rc/jobs"
	rsync "github.com/rclone/rclone/fs/sync"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

// Conflict copy suffixes (bisync appends a number, before the extension).
const (
	SuffixLocal  = "conflict-local"
	SuffixRemote = "conflict-remote"
)

// LocalFs returns the rclone fs string for a job's local folder.
func LocalFs(j model.Job) string {
	if j.Filters.SkipSymlinks {
		return ":local,skip_links:" + j.LocalPath
	}
	return j.LocalPath
}

// RemoteFs returns the rclone fs string for remote:path. A leading slash
// is kept: on sftp/ftp/local it means an absolute path.
func RemoteFs(remote, p string) string {
	if id, sub, ok := ParseComputerPath(p); ok {
		return remote + ",root_folder_id=" + id + ":" + strings.Trim(sub, "/")
	}
	if p != "/" {
		p = strings.TrimRight(p, "/")
	}
	return remote + ":" + p
}

func joinFs(base, rel string) string {
	if strings.HasSuffix(base, ":") {
		return base + rel
	}
	if strings.Contains(base, ":") && !filepath.IsAbs(base) {
		return strings.TrimRight(base, "/") + "/" + rel
	}
	return filepath.Join(base, filepath.FromSlash(rel))
}

// runContext attaches the job's filter and per-run config to ctx.
func runContext(ctx context.Context, spec RunSpec) (context.Context, *fs.ConfigInfo, error) {
	var fi *filter.Filter
	var err error
	if spec.Files != nil {
		opt := filter.Opt
		opt.RulesOpt = filter.RulesOpt{}
		opt.ExcludeFile = nil
		fi, err = filter.NewFilter(&opt)
		if err == nil {
			for _, f := range spec.Files {
				_ = fi.AddFile(f)
			}
		}
	} else {
		fi, err = spec.Filter.Rclone(true)
	}
	if err != nil {
		return nil, nil, fmt.Errorf("filters: %w", err)
	}
	ctx = filter.ReplaceConfig(ctx, fi)
	ctx, ci := fs.AddConfig(ctx)
	if spec.Job.Limits.Transfers > 0 {
		ci.Transfers = spec.Job.Limits.Transfers
	}
	if spec.Job.Limits.Checkers > 0 {
		ci.Checkers = spec.Job.Limits.Checkers
	}
	ci.CheckSum = spec.Job.Safety.Checksum
	ci.DryRun = spec.DryRun
	ci.MaxDelete = -1
	ci.SuffixKeepExtension = true
	if spec.Files != nil {
		ci.NoTraverse = true
	}
	return ctx, ci, nil
}

// Run executes one run of a job.
func (r *Rclone) Run(ctx context.Context, spec RunSpec, progress ProgressFn) RunResult {
	if spec.Now.IsZero() {
		spec.Now = time.Now()
	}
	var mu sync.Mutex
	var conflictLines []string
	unregister := r.register(spec.Job.ID, spec.RunID, func(msg string) {
		if strings.Contains(msg, "New or changed in both paths") {
			mu.Lock()
			conflictLines = append(conflictLines, msg)
			mu.Unlock()
		}
	})
	defer unregister()

	group := spec.RunID
	ctx = accounting.WithStatsGroup(ctx, group)
	defer deleteStatsGroup(group)

	ph := &runPhase{}
	if progress != nil {
		inner := progress
		progress = func(p model.Progress) {
			p.Phase, p.Step, p.Steps = ph.get()
			inner(p)
		}
	}
	stopPoll := pollProgress(ctx, group, progress)
	var res RunResult
	if spec.Job.Direction == model.DirTwoWay {
		res = r.bisync(ctx, spec)
	} else {
		res = r.oneWay(ctx, spec, ph)
	}
	stopPoll()

	stats := accounting.StatsGroup(ctx, group)
	res.Bytes = stats.GetBytes()
	res.Files = stats.GetTransfers()
	res.Deletes = stats.GetDeletes()
	if spec.Job.Direction == model.DirTwoWay {
		mu.Lock()
		res.Conflicts = findConflicts(spec.Job.LocalPath, conflictLines)
		mu.Unlock()
	}
	if res.Err != nil && res.Fail == FailNone {
		res.Fail = Classify(res.Err)
	}
	if res.Err == nil && !spec.DryRun && spec.Job.DeletePolicy == model.DeleteArchive {
		r.pruneArchives(ctx, spec)
	}
	return res
}

// runPhase is the part of a folder-by-folder run that is running now.
type runPhase struct {
	mu          sync.Mutex
	name        string
	step, steps int
}

func (p *runPhase) set(name string, step, steps int) {
	p.mu.Lock()
	p.name, p.step, p.steps = name, step, steps
	p.mu.Unlock()
}

func (p *runPhase) get() (string, int, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.name, p.step, p.steps
}

// Folders checked at the top level of a job. A job with at least this many
// is synced one top-level folder at a time.
const minFoldersToSplit = 2

func (r *Rclone) oneWay(ctx context.Context, spec RunSpec, ph *runPhase) RunResult {
	ctx, ci, err := runContext(ctx, spec)
	if err != nil {
		return RunResult{Err: err, Fail: FailOther}
	}
	srcS, dstS := LocalFs(spec.Job), RemoteFs(spec.Remote, spec.Job.RemotePath)
	if spec.Job.Direction == model.DirDownload {
		srcS, dstS = dstS, srcS
	}
	fsrc, err := fs.NewFs(ctx, srcS)
	if err != nil {
		return RunResult{Err: fmt.Errorf("source: %w", err)}
	}
	fdst, err := fs.NewFs(ctx, dstS)
	if err != nil {
		return RunResult{Err: fmt.Errorf("destination: %w", err)}
	}
	mirror := spec.Job.DeletePolicy != model.DeleteNever && spec.Files == nil
	archive := ""
	if mirror && spec.Job.DeletePolicy == model.DeleteArchive {
		archive = joinFs(dstS, filters.ArchiveDir+"/"+spec.Now.Format("2006-01-02"))
	}

	// Large trees: one top-level folder at a time. Each part lists, checks and
	// transfers on its own, so work starts right away, progress is visible and
	// one slow or failing folder doesn't hold up the rest.
	var folders []string
	if spec.Files == nil && spec.Filter != nil && !spec.Filter.Anchored() {
		folders = topFolders(ctx, fsrc, spec)
	}
	if len(folders) < minFoldersToSplit {
		ci.BackupDir = archive
		res, _ := syncPart(ctx, spec, fsrc, fdst, mirror, 0, 0)
		return res
	}

	steps := len(folders) + 1
	var firstErr *RunResult
	seen := 0 // destination files checked so far, for the top-level part's guard
	for i, f := range folders {
		if ctx.Err() != nil {
			return RunResult{Err: ctx.Err()}
		}
		ph.set(f, i+1, steps)
		fs1, err := fs.NewFs(ctx, joinFs(srcS, f))
		if err != nil {
			if firstErr == nil {
				firstErr = &RunResult{Err: fmt.Errorf("%s: %w", f, err)}
			}
			continue
		}
		fd1, err := fs.NewFs(ctx, joinFs(dstS, f))
		if err != nil {
			if firstErr == nil {
				firstErr = &RunResult{Err: fmt.Errorf("%s: %w", f, err)}
			}
			continue
		}
		if archive != "" {
			ci.BackupDir = joinFs(archive, f)
		}
		res, total := syncPart(ctx, spec, fs1, fd1, mirror, 20, 0)
		seen += total
		if res.Err != nil {
			res.Err = fmt.Errorf("%s: %w", f, res.Err)
			if res.Fail == FailMaxDelete {
				return res
			}
			if firstErr == nil {
				firstErr = &res
			}
		}
	}
	// Last part: files at the top level, plus anything in the destination's
	// top level the source doesn't have (mirror removes those, e.g. a folder
	// deleted or renamed on this side). Its deletion guard is measured against
	// the whole job, not just this part.
	ph.set("", steps, steps)
	rootFi, err := spec.Filter.Rclone(true)
	if err != nil {
		return RunResult{Err: fmt.Errorf("filters: %w", err), Fail: FailOther}
	}
	for _, f := range folders {
		if err := rootFi.AddRule("- /" + globEscape(f) + "/**"); err != nil {
			return RunResult{Err: fmt.Errorf("filters: %w", err), Fail: FailOther}
		}
	}
	ci.BackupDir = archive
	last, _ := syncPart(filter.ReplaceConfig(ctx, rootFi), spec, fsrc, fdst, mirror, 0, seen)
	ph.set("", 0, 0)
	if last.Err != nil && (last.Fail == FailMaxDelete || firstErr == nil) {
		return last
	}
	if firstErr != nil {
		return *firstErr
	}
	return RunResult{}
}

// syncPart runs one rclone sync/copy, guarded by the max-delete check.
// syncPart runs one rclone sync/copy, guarded by the max-delete check. It
// returns the number of destination files it compared. extraTotal adds files
// checked by earlier parts to the guard's denominator.
func syncPart(ctx context.Context, spec RunSpec, fsrc, fdst fs.Fs, mirror bool, minDeletes, extraTotal int) (RunResult, int) {
	dstTotal := 0
	if mirror && !spec.Force && !spec.DryRun && spec.Job.Safety.MaxDeletePercent < 100 {
		d, err := diff(ctx, fsrc, fdst, 0)
		if err != nil {
			return RunResult{Err: err}, 0
		}
		dstTotal = d.dstTotal
		total := d.dstTotal + extraTotal
		// In a folder-by-folder run a small part can't trip the guard on its
		// own: a 2-file folder losing one file is not a mass deletion.
		if len(d.dstOnly) > minDeletes && exceeds(len(d.dstOnly), total, spec.Job.Safety.MaxDeletePercent) {
			return RunResult{Fail: FailMaxDelete, Err: fmt.Errorf("too many deletes: %d of %d files (%d%%) would be deleted, limit is %d%%",
				len(d.dstOnly), total, len(d.dstOnly)*100/max(1, total), spec.Job.Safety.MaxDeletePercent)}, dstTotal
		}
	}
	fn := func(ctx context.Context, _ rc.Params) (rc.Params, error) {
		if mirror {
			return nil, rsync.Sync(ctx, fdst, fsrc, false)
		}
		return nil, rsync.CopyDir(ctx, fdst, fsrc, false)
	}
	_, _, err := jobs.NewJob(ctx, fn, rc.Params{"_group": spec.RunID})
	return RunResult{Err: err}, dstTotal
}

// topFolders lists the source's top-level folders that the job's filters keep.
func topFolders(ctx context.Context, fsrc fs.Fs, spec RunSpec) []string {
	entries, err := fsrc.List(ctx, "")
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		d, ok := e.(fs.Directory)
		if !ok {
			continue
		}
		name := path.Base(d.Remote())
		if excluded, _ := spec.Filter.ExcludesDir(name); excluded {
			continue
		}
		if name == filters.ArchiveDir || hasMarker(spec, name) {
			continue
		}
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// hasMarker reports whether a local top-level folder holds an exclude marker
// such as .nosync (rclone doesn't apply the marker to the root of a run).
func hasMarker(spec RunSpec, name string) bool {
	if spec.Job.Direction == model.DirDownload {
		return false
	}
	for _, m := range spec.Job.Filters.ExcludeIfPresent {
		if _, err := os.Stat(filepath.Join(spec.Job.LocalPath, name, m)); err == nil {
			return true
		}
	}
	return false
}

// globEscape escapes rclone glob characters in a literal name.
func globEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(`\*?[]{}`, r) {
			b.WriteRune('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func exceeds(deletes, total, pct int) bool {
	if deletes == 0 || total == 0 {
		return false
	}
	return deletes*100 > pct*total
}

func (r *Rclone) bisync(ctx context.Context, spec RunSpec) RunResult {
	ctx, _, err := runContext(ctx, spec)
	if err != nil {
		return RunResult{Err: err, Fail: FailOther}
	}
	p1, p2 := LocalFs(spec.Job), RemoteFs(spec.Remote, spec.Job.RemotePath)
	f1, err := fs.NewFs(ctx, p1)
	if err != nil {
		return RunResult{Err: fmt.Errorf("local: %w", err)}
	}
	f2, err := fs.NewFs(ctx, p2)
	if err != nil {
		return RunResult{Err: fmt.Errorf("remote: %w", err)}
	}
	// Listing file names derive from both paths; most filesystems cap a
	// name at 255 bytes.
	if n := len(bilib.SessionName(f1, f2)) + len(".path1.lst-dry-new"); n > 255 {
		return RunResult{Fail: FailPathTooLong, Err: fmt.Errorf("two-way sync state file name would be %d characters (limit 255): use shorter local or remote folder paths", n)}
	}
	params := rc.Params{
		"path1":           p1,
		"path2":           p2,
		"workdir":         spec.WorkDir,
		"resync":          spec.Resync,
		"resilient":       true,
		"recover":         true,
		"force":           spec.Force,
		"dryRun":          spec.DryRun,
		"maxDelete":       int64(spec.Job.Safety.MaxDeletePercent),
		"conflictResolve": conflictResolve(spec.Job.ConflictPolicy),
		"conflictLoser":   "num",
		"conflictSuffix":  SuffixLocal + "," + SuffixRemote,
		"compare":         "size,modtime",
		"_group":          spec.RunID,
	}
	if spec.Job.Safety.Checksum {
		params["compare"] = "size,modtime,checksum"
	}
	if spec.Job.DeletePolicy == model.DeleteArchive {
		day := filters.ArchiveDir + "/" + spec.Now.Format("2006-01-02")
		params["backupDir1"] = joinFs(p1, day)
		params["backupDir2"] = joinFs(p2, day)
	}
	call := rc.Calls.Get("sync/bisync")
	if call == nil {
		return RunResult{Err: errors.New("sync/bisync not registered")}
	}
	_, _, err = jobs.NewJob(ctx, call.Fn, params)
	return RunResult{Err: err}
}

func conflictResolve(p string) string {
	switch p {
	case model.ConflictNewer:
		return "newer"
	case model.ConflictPreferLocal:
		return "path1"
	case model.ConflictPreferRemote:
		return "path2"
	}
	return "none" // keepBoth, ask: keep both copies
}

var conflictRe = regexp.MustCompile(`New or changed in both paths\s+-\s+(.+)$`)

// findConflicts maps bisync conflict log lines to the copies on disk.
func findConflicts(localRoot string, lines []string) []Conflict {
	seen := map[string]bool{}
	var out []Conflict
	for _, l := range lines {
		m := conflictRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		p := strings.TrimSpace(m[1])
		if strings.HasPrefix(p, `"`) {
			if u, err := strconv.Unquote(p); err == nil {
				p = u
			}
		}
		if seen[p] {
			continue
		}
		seen[p] = true
		c := Conflict{Path: p, LocalCopy: latestCopy(localRoot, p, SuffixLocal), RemoteCopy: latestCopy(localRoot, p, SuffixRemote)}
		if c.LocalCopy == "" && c.RemoteCopy == "" {
			continue // identical content, nothing was renamed
		}
		out = append(out, c)
	}
	return out
}

// latestCopy finds "<stem>.<suffix><N><ext>" next to rel with the highest N.
func latestCopy(root, rel, suffix string) string {
	dir, base := path.Split(rel)
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	re := regexp.MustCompile("^" + regexp.QuoteMeta(stem+"."+suffix) + `(\d+)` + regexp.QuoteMeta(ext) + "$")
	entries, err := readDirNames(filepath.Join(root, filepath.FromSlash(dir)))
	if err != nil {
		return ""
	}
	best, bestN := "", -1
	for _, name := range entries {
		if m := re.FindStringSubmatch(name); m != nil {
			if n, _ := strconv.Atoi(m[1]); n > bestN {
				best, bestN = dir+name, n
			}
		}
	}
	return best
}

// Classify maps an error to a failure kind.
func Classify(err error) string {
	if err == nil {
		return FailNone
	}
	if errors.Is(err, context.Canceled) {
		return FailCancelled
	}
	s := strings.ToLower(err.Error())
	switch {
	case strings.Contains(s, "too many deletes"):
		return FailMaxDelete
	case strings.Contains(s, "must run --resync"), strings.Contains(s, "cannot find prior path1 or path2 listings"),
		strings.Contains(s, "run --resync"), strings.Contains(s, "bisync aborted"):
		return FailNeedsResync
	case strings.Contains(s, "invalid_grant"), strings.Contains(s, "token expired"), strings.Contains(s, "couldn't fetch token"),
		strings.Contains(s, "unauthorized"), strings.Contains(s, "401"), strings.Contains(s, "invalid_client"),
		strings.Contains(s, "authentication failed"), strings.Contains(s, "unable to authenticate"):
		return FailAuth
	case strings.Contains(s, "quota"), strings.Contains(s, "insufficient storage"), strings.Contains(s, "507"),
		strings.Contains(s, "no space left"):
		return FailQuota
	case strings.Contains(s, "permission denied"), strings.Contains(s, "access denied"), strings.Contains(s, "403"),
		strings.Contains(s, "operation not permitted"):
		return FailPermission
	}
	return FailOther
}

func deleteStatsGroup(group string) {
	if call := rc.Calls.Get("core/stats-delete"); call != nil {
		_, _ = call.Fn(context.Background(), rc.Params{"group": group})
	}
}
