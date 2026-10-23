// Package watch watches job folders recursively (fsnotify), prunes
// excluded directories, debounces changes per job and reports them.
package watch

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/pigment-dev/rclone/core/internal/filters"
)

// MaxDirs caps the watched directories per job. kqueue (macOS/BSD) needs a
// descriptor per watched entry, so huge trees fall back to scheduled full
// runs (Change.Overflow) instead of exhausting file descriptors.
var MaxDirs = 4000

// MaxPaths is the largest change set reported as individual paths.
const MaxPaths = 1000

// Change is a debounced batch of changes for one job.
type Change struct {
	Paths    []string // relative slash paths of created/modified files
	Removed  bool     // something was deleted or renamed away
	Overflow bool     // too many events / watch limits: do a full run
}

// Handler receives debounced changes.
type Handler func(jobID string, c Change)

// Job is one watched folder.
type Job struct {
	ID       string
	Root     string
	Filter   *filters.Compiled
	Debounce time.Duration
}

type jobWatch struct {
	Job
	fw      *fsnotify.Watcher
	handler Handler
	mu      sync.Mutex
	pending map[string]struct{}
	removed bool
	over    bool
	timer   *time.Timer
	dirs    int
	limited bool
	done    chan struct{}
}

// Watcher manages per-job watches.
type Watcher struct {
	mu      sync.Mutex
	jobs    map[string]*jobWatch
	handler Handler
}

// New returns a Watcher calling h on debounced changes.
func New(h Handler) *Watcher {
	return &Watcher{jobs: map[string]*jobWatch{}, handler: h}
}

// Set starts or replaces the watch for a job.
func (w *Watcher) Set(j Job) error {
	w.Remove(j.ID)
	fw, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	if j.Debounce <= 0 {
		j.Debounce = 10 * time.Second
	}
	jw := &jobWatch{Job: j, fw: fw, handler: w.handler, pending: map[string]struct{}{}, done: make(chan struct{})}
	if err := jw.addTree(j.Root, false); err != nil {
		_ = fw.Close()
		return err
	}
	w.mu.Lock()
	w.jobs[j.ID] = jw
	w.mu.Unlock()
	go jw.loop()
	return nil
}

// Remove stops watching a job.
func (w *Watcher) Remove(id string) {
	w.mu.Lock()
	jw := w.jobs[id]
	delete(w.jobs, id)
	w.mu.Unlock()
	if jw != nil {
		jw.stop()
	}
}

// Close stops all watches.
func (w *Watcher) Close() {
	w.mu.Lock()
	jobs := w.jobs
	w.jobs = map[string]*jobWatch{}
	w.mu.Unlock()
	for _, jw := range jobs {
		jw.stop()
	}
}

// Watching reports whether a job is watched (for tests/diagnostics).
func (w *Watcher) Watching(id string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.jobs[id] != nil
}

func (jw *jobWatch) stop() {
	close(jw.done)
	_ = jw.fw.Close()
	jw.mu.Lock()
	if jw.timer != nil {
		jw.timer.Stop()
	}
	jw.mu.Unlock()
}

func (jw *jobWatch) rel(p string) (string, bool) {
	r, err := filepath.Rel(jw.Root, p)
	if err != nil || r == "." || strings.HasPrefix(r, "..") {
		return "", false
	}
	return filepath.ToSlash(r), true
}

// excluded reports whether rel or one of its parents is filtered out.
func (jw *jobWatch) excluded(rel string, isDir bool) bool {
	if rel == filters.ArchiveDir || strings.HasPrefix(rel, filters.ArchiveDir+"/") {
		return true
	}
	parts := strings.Split(rel, "/")
	n := len(parts) - 1
	if isDir {
		n = len(parts)
	}
	for i := 1; i <= n; i++ {
		if ex, _ := jw.Filter.ExcludesDir(strings.Join(parts[:i], "/")); ex {
			return true
		}
	}
	if !isDir {
		inc, _ := jw.Filter.MatchPath(rel)
		return !inc
	}
	return false
}

// addTree watches dir and its non-excluded subdirectories. When report is
// set, files found are queued as changes (a folder created or moved in).
func (jw *jobWatch) addTree(dir string, report bool) error {
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p == dir {
				return err
			}
			return nil
		}
		rel, _ := jw.rel(p)
		if d.IsDir() {
			if rel != "" && jw.excluded(rel, true) {
				return filepath.SkipDir
			}
			if jw.Filter.DirMarker(p) != "" {
				return filepath.SkipDir
			}
			if jw.dirs >= MaxDirs || jw.fw.Add(p) != nil {
				jw.mu.Lock()
				jw.limited = true
				jw.mu.Unlock()
				return filepath.SkipAll
			}
			jw.dirs++
			return nil
		}
		if report && rel != "" && !jw.excluded(rel, false) {
			jw.mu.Lock()
			jw.pending[rel] = struct{}{}
			jw.mu.Unlock()
		}
		return nil
	})
}

func (jw *jobWatch) loop() {
	for {
		select {
		case <-jw.done:
			return
		case ev, ok := <-jw.fw.Events:
			if !ok {
				return
			}
			jw.handle(ev)
		case err, ok := <-jw.fw.Errors:
			if !ok {
				return
			}
			if errors.Is(err, fsnotify.ErrEventOverflow) {
				jw.mu.Lock()
				jw.over = true
				jw.mu.Unlock()
				jw.arm()
			}
		}
	}
}

func (jw *jobWatch) handle(ev fsnotify.Event) {
	rel, ok := jw.rel(ev.Name)
	if !ok {
		return
	}
	switch {
	case ev.Has(fsnotify.Remove) || ev.Has(fsnotify.Rename):
		if jw.excluded(rel, false) && jw.excluded(rel, true) {
			return
		}
		jw.mu.Lock()
		jw.removed = true
		delete(jw.pending, rel)
		jw.mu.Unlock()
	case ev.Has(fsnotify.Create) || ev.Has(fsnotify.Write):
		fi, err := os.Lstat(ev.Name)
		if err != nil {
			return
		}
		if fi.IsDir() {
			if jw.excluded(rel, true) {
				return
			}
			_ = jw.addTree(ev.Name, true)
			jw.mu.Lock()
			if jw.limited {
				jw.over = true
			}
			jw.mu.Unlock()
		} else {
			if jw.excluded(rel, false) {
				return
			}
			jw.mu.Lock()
			jw.pending[rel] = struct{}{}
			if len(jw.pending) > MaxPaths {
				jw.over = true
			}
			jw.mu.Unlock()
		}
	default:
		return // chmod etc.
	}
	jw.arm()
}

// arm (re)starts the debounce timer.
func (jw *jobWatch) arm() {
	jw.mu.Lock()
	defer jw.mu.Unlock()
	if jw.timer == nil {
		jw.timer = time.AfterFunc(jw.Debounce, jw.fire)
		return
	}
	jw.timer.Reset(jw.Debounce)
}

func (jw *jobWatch) fire() {
	jw.mu.Lock()
	c := Change{Removed: jw.removed, Overflow: jw.over}
	if !c.Overflow {
		c.Paths = make([]string, 0, len(jw.pending))
		for p := range jw.pending {
			c.Paths = append(c.Paths, p)
		}
	}
	jw.pending = map[string]struct{}{}
	jw.removed, jw.over = false, false
	jw.mu.Unlock()
	select {
	case <-jw.done:
		return
	default:
	}
	if len(c.Paths) == 0 && !c.Removed && !c.Overflow {
		return
	}
	jw.handler(jw.ID, c)
}

// Limited reports whether the job hit the watch limit (full runs only).
func (w *Watcher) Limited(id string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if jw := w.jobs[id]; jw != nil {
		jw.mu.Lock()
		defer jw.mu.Unlock()
		return jw.limited
	}
	return false
}
