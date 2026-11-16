package watch

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

func TestDebounceAndPrune(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	for _, d := range []string{"src", "node_modules/pkg", ".git/objects"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	c, err := filters.Compile(model.Filters{Presets: []string{"vcs", "deps", "osjunk"}}, filters.Options{})
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan Change, 4)
	w := New(func(id string, ch Change) { got <- ch })
	defer w.Close()
	if err := w.Set(Job{ID: "job_w", Root: root, Filter: c, Debounce: 300 * time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	write := func(rel string) {
		if err := os.WriteFile(filepath.Join(root, rel), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("src/a.go")
	write("node_modules/pkg/index.js")
	write(".git/objects/abc")
	write(".DS_Store")
	time.Sleep(100 * time.Millisecond)
	write("src/b.go")
	// A folder created after the watch started is picked up recursively.
	if err := os.MkdirAll(filepath.Join(root, "src", "new"), 0o755); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	write("src/new/c.go")

	// Events can arrive late on some systems (Windows CI), splitting them
	// over more than one debounced batch: collect until all are seen.
	want := []string{"src/a.go", "src/b.go", "src/new/c.go"}
	var paths []string
	deadline := time.After(5 * time.Second)
	for !slices.Equal(paths, want) {
		select {
		case ch := <-got:
			if ch.Overflow {
				t.Fatalf("unexpected overflow %+v", ch)
			}
			for _, p := range ch.Paths {
				if !slices.Contains(paths, p) {
					paths = append(paths, p)
				}
			}
			slices.Sort(paths)
			for _, p := range paths {
				if !slices.Contains(want, p) {
					t.Fatalf("excluded path reported: %s", p)
				}
			}
		case <-deadline:
			t.Fatalf("got paths %v, want %v", paths, want)
		}
	}
	// Let any trailing batch settle before the removal check.
	time.Sleep(500 * time.Millisecond)
	for len(got) > 0 {
		<-got
	}
	if err := os.Remove(filepath.Join(root, "src", "a.go")); err != nil {
		t.Fatal(err)
	}
	select {
	case ch := <-got:
		if !ch.Removed {
			t.Fatalf("removal not reported: %+v", ch)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no removal change")
	}
}
