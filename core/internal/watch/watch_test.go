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

	select {
	case ch := <-got:
		slices.Sort(ch.Paths)
		want := []string{"src/a.go", "src/b.go", "src/new/c.go"}
		if !slices.Equal(ch.Paths, want) || ch.Overflow {
			t.Fatalf("change = %+v, want paths %v", ch, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no debounced change")
	}
	select {
	case ch := <-got:
		t.Fatalf("unexpected second batch %+v", ch)
	case <-time.After(500 * time.Millisecond):
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
