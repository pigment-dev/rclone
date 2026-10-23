package engine

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"

	rfs "github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/march"
	"github.com/rclone/rclone/fs/operations"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

// SampleSize caps each preview sample list.
const SampleSize = 50

type diffEntry struct {
	path string
	size int64
}

// diffResult is a listing-level comparison of src and dst.
type diffResult struct {
	srcOnly  []diffEntry // capped at sampleCap (counts below are exact)
	dstOnly  []diffEntry
	differ   []diffEntry
	nSrcOnly int
	nDiffer  int
	bytes    int64 // bytes of srcOnly + differ
	dstTotal int   // files present on dst
	mu       gosync.Mutex
	cap      int
	ctx      context.Context
}

func (d *diffResult) add(list *[]diffEntry, e diffEntry) {
	if d.cap <= 0 || len(*list) < d.cap {
		*list = append(*list, e)
	}
}

func isDir(e rfs.DirEntry) bool {
	_, ok := e.(rfs.Directory)
	return ok
}

func (d *diffResult) SrcOnly(src rfs.DirEntry) bool {
	if o, ok := src.(rfs.Object); ok {
		d.mu.Lock()
		d.nSrcOnly++
		d.bytes += max(0, o.Size())
		d.add(&d.srcOnly, diffEntry{o.Remote(), o.Size()})
		d.mu.Unlock()
	}
	return isDir(src)
}

func (d *diffResult) DstOnly(dst rfs.DirEntry) bool {
	if o, ok := dst.(rfs.Object); ok {
		d.mu.Lock()
		d.dstTotal++
		d.dstOnly = append(d.dstOnly, diffEntry{o.Remote(), o.Size()}) // uncapped: needed for counts
		d.mu.Unlock()
	}
	return isDir(dst)
}

func (d *diffResult) Match(ctx context.Context, dst, src rfs.DirEntry) bool {
	so, ok1 := src.(rfs.Object)
	do, ok2 := dst.(rfs.Object)
	if !ok1 || !ok2 {
		return isDir(src) && isDir(dst)
	}
	need := operations.NeedTransfer(ctx, do, so)
	d.mu.Lock()
	d.dstTotal++
	if need {
		d.nDiffer++
		d.bytes += max(0, so.Size())
		d.add(&d.differ, diffEntry{so.Remote(), so.Size()})
	}
	d.mu.Unlock()
	return false
}

// diff marches src against dst using the filter in ctx. It uses its own
// stats group so it never pollutes a run's progress.
func diff(ctx context.Context, fsrc, fdst rfs.Fs, sampleCap int) (*diffResult, error) {
	group := fmt.Sprintf("diff-%p", &sampleCap)
	ctx = accounting.WithStatsGroup(ctx, group)
	defer deleteStatsGroup(group)
	d := &diffResult{cap: sampleCap, ctx: ctx}
	m := &march.March{Ctx: ctx, Fdst: fdst, Fsrc: fsrc, Callback: d}
	if err := m.Run(ctx); err != nil {
		return nil, err
	}
	return d, nil
}

// Preview computes what a run would do, without changing anything.
func (r *Rclone) Preview(ctx context.Context, spec RunSpec) (*model.Preview, error) {
	spec.DryRun = true
	spec.Files = nil
	rctx, _, err := runContext(ctx, spec)
	if err != nil {
		return nil, err
	}
	local, remote := LocalFs(spec.Job), RemoteFs(spec.Remote, spec.Job.RemotePath)
	src, dst := local, remote
	if spec.Job.Direction == model.DirDownload {
		src, dst = remote, local
	}
	fsrc, err := rfs.NewFs(rctx, src)
	if err != nil {
		return nil, fmt.Errorf("source: %w", err)
	}
	fdst, err := rfs.NewFs(rctx, dst)
	if err != nil {
		return nil, fmt.Errorf("destination: %w", err)
	}
	d, err := diff(rctx, fsrc, fdst, SampleSize)
	if err != nil {
		return nil, err
	}
	p := &model.Preview{Bytes: d.bytes, Sample: model.PreviewSample{Adds: []string{}, Updates: []string{}, Deletes: []string{}, Excluded: []model.Excluded{}}}
	p.Adds, p.Updates = d.nSrcOnly, d.nDiffer
	for _, e := range d.srcOnly {
		p.Sample.Adds = append(p.Sample.Adds, e.path)
	}
	for _, e := range d.differ {
		p.Sample.Updates = append(p.Sample.Updates, e.path)
	}
	switch {
	case spec.Job.Direction == model.DirTwoWay:
		// Without prior listings a two-way run cannot tell a remote-only
		// file from a local delete; the baseline copies it down.
		p.Adds += len(d.dstOnly)
		for _, e := range d.dstOnly {
			if len(p.Sample.Adds) < SampleSize {
				p.Sample.Adds = append(p.Sample.Adds, e.path)
			}
			p.Bytes += max(0, e.size)
		}
	case spec.Job.DeletePolicy != model.DeleteNever:
		p.Deletes = len(d.dstOnly)
		for _, e := range d.dstOnly {
			if len(p.Sample.Deletes) < SampleSize {
				p.Sample.Deletes = append(p.Sample.Deletes, e.path)
			}
		}
	}
	if spec.Job.Direction != model.DirDownload {
		p.Excluded, p.Sample.Excluded = walkExcluded(spec.Job.LocalPath, spec.Filter, SampleSize)
	}
	return p, nil
}

// walkExcluded walks the local tree and lists what the filter excludes.
// Excluded folders count once and are not descended into.
func walkExcluded(root string, c *filters.Compiled, sampleCap int) (int, []model.Excluded) {
	count := 0
	sample := []model.Excluded{}
	note := func(rel, rule string) {
		count++
		if len(sample) < sampleCap {
			sample = append(sample, model.Excluded{Path: rel, Rule: rule})
		}
	}
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if ex, why := c.ExcludesDir(rel); ex {
				note(rel+"/", why)
				return filepath.SkipDir
			}
			if m := c.DirMarker(p); m != "" {
				note(rel+"/", fmt.Sprintf("folder contains %s (exclude-if-present)", m))
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(rel, filters.ArchiveDir+"/") {
			return nil
		}
		fi, _ := d.Info()
		if ok, why := c.ExplainEntry(rel, fi); !ok && why != nil {
			note(rel, *why)
		}
		return nil
	})
	return count, sample
}

// statLocal reports whether a local path exists (used by conflict resolve).
func statLocal(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}
