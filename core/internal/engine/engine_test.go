package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/filters"
	"github.com/pigment-dev/rclone/core/internal/model"
)

var eng *Rclone

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "pdr")
	if err != nil {
		panic(err)
	}
	eng, err = NewRclone(Options{ConfigPath: filepath.Join(dir, "rclone.conf"), Passphrase: "test-pass", LogLevel: "info"})
	if err != nil {
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// shortDir returns a short temp dir (bisync listing names embed full paths).
func shortDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("", "pdr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	d, _ = filepath.EvalSymlinks(d)
	return d
}

func write(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, root, rel string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return "", false
	}
	return string(b), true
}

func job(local, remote, dir, del, conflict string) model.Job {
	return model.Job{
		ID: "job_t" + filepath.Base(local), Name: "test", Enabled: true, LocalPath: local, AccountID: "acc", RemotePath: remote,
		Direction: dir, DeletePolicy: del, ConflictPolicy: conflict, ArchiveRetentionDays: 30,
		Filters: model.Filters{Presets: []string{"vcs", "ide", "deps", "osjunk"}, ExcludeIfPresent: []string{".nosync"}},
		Limits:  model.Limits{Transfers: 2, Checkers: 4},
		Safety:  model.Safety{MaxDeletePercent: 100},
	}
}

func spec(t *testing.T, j model.Job) RunSpec {
	t.Helper()
	c, err := filters.Compile(j.Filters, filters.Options{LocalRoot: j.LocalPath})
	if err != nil {
		t.Fatal(err)
	}
	return RunSpec{RunID: "run_" + filepath.Base(j.LocalPath) + time.Now().Format("150405.000000"), Job: j, Remote: ":local", Filter: c,
		WorkDir: filepath.Join(filepath.Dir(j.LocalPath), filepath.Base(j.LocalPath)+"-wd"), Now: time.Now()}
}

func mustRun(t *testing.T, s RunSpec) RunResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	res := eng.Run(ctx, s, nil)
	if res.Err != nil {
		t.Fatalf("run failed (%s): %v", res.Fail, res.Err)
	}
	return res
}

func seedTree(t *testing.T, root string) {
	write(t, root, "a.txt", "alpha")
	write(t, root, "sub/b.txt", "bravo")
	write(t, root, ".git/config", "[core]")
	write(t, root, "proj/.claude/settings.json", "{}")
	write(t, root, "proj/node_modules/x/index.js", "js")
	write(t, root, ".DS_Store", "junk")
	write(t, root, "private/.nosync", "")
	write(t, root, "private/secret.txt", "s")
}

func TestUploadMirrorExcludes(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	seedTree(t, local)
	j := job(local, remote, model.DirUpload, model.DeleteMirror, model.ConflictNewer)
	res := mustRun(t, spec(t, j))
	if res.Files != 2 {
		t.Errorf("files = %d, want 2", res.Files)
	}
	for _, rel := range []string{"a.txt", "sub/b.txt"} {
		if _, ok := read(t, remote, rel); !ok {
			t.Errorf("%s missing on remote", rel)
		}
	}
	for _, rel := range []string{".git/config", "proj/.claude/settings.json", "proj/node_modules/x/index.js", ".DS_Store", "private/secret.txt"} {
		if _, ok := read(t, remote, rel); ok {
			t.Errorf("%s must be excluded", rel)
		}
	}
	_ = os.Remove(filepath.Join(local, "a.txt"))
	mustRun(t, spec(t, j))
	if _, ok := read(t, remote, "a.txt"); ok {
		t.Error("mirror should delete a.txt on remote")
	}
}

func TestUploadNeverAndArchive(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	seedTree(t, local)
	never := job(local, remote, model.DirUpload, model.DeleteNever, model.ConflictNewer)
	mustRun(t, spec(t, never))
	_ = os.Remove(filepath.Join(local, "a.txt"))
	mustRun(t, spec(t, never))
	if _, ok := read(t, remote, "a.txt"); !ok {
		t.Error("never-delete policy removed a.txt")
	}
	archive := job(local, remote, model.DirUpload, model.DeleteArchive, model.ConflictNewer)
	s := spec(t, archive)
	mustRun(t, s)
	if _, ok := read(t, remote, "a.txt"); ok {
		t.Error("archive policy should remove a.txt from the mirror")
	}
	day := s.Now.Format("2006-01-02")
	if got, ok := read(t, remote, filters.ArchiveDir+"/"+day+"/a.txt"); !ok || got != "alpha" {
		t.Errorf("a.txt not archived (got %q, %v)", got, ok)
	}
	// The archive itself must never be mirrored back or deleted.
	mustRun(t, spec(t, archive))
	if _, ok := read(t, remote, filters.ArchiveDir+"/"+day+"/a.txt"); !ok {
		t.Error("archive was pruned by a later run")
	}
}

func TestDownloadMirror(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	write(t, remote, "doc.txt", "remote doc")
	write(t, local, "stale.txt", "old")
	j := job(local, remote, model.DirDownload, model.DeleteMirror, model.ConflictNewer)
	mustRun(t, spec(t, j))
	if got, _ := read(t, local, "doc.txt"); got != "remote doc" {
		t.Errorf("doc.txt = %q", got)
	}
	if _, ok := read(t, local, "stale.txt"); ok {
		t.Error("download mirror should delete stale.txt")
	}
}

func TestMaxDeleteAbort(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	for i := range 10 {
		write(t, local, "f"+string(rune('a'+i))+".txt", "x")
	}
	j := job(local, remote, model.DirUpload, model.DeleteMirror, model.ConflictNewer)
	j.Safety.MaxDeletePercent = 25
	mustRun(t, spec(t, j))
	for i := range 5 {
		_ = os.Remove(filepath.Join(local, "f"+string(rune('a'+i))+".txt"))
	}
	res := eng.Run(context.Background(), spec(t, j), nil)
	if res.Fail != FailMaxDelete {
		t.Fatalf("fail = %q (%v), want maxDelete", res.Fail, res.Err)
	}
	if _, ok := read(t, remote, "fa.txt"); !ok {
		t.Error("nothing may be deleted when the guard trips")
	}
	s := spec(t, j)
	s.Force = true
	mustRun(t, s)
	if _, ok := read(t, remote, "fa.txt"); ok {
		t.Error("forced run should delete")
	}
}

func TestFilesFastPath(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	seedTree(t, local)
	j := job(local, remote, model.DirUpload, model.DeleteMirror, model.ConflictNewer)
	s := spec(t, j)
	s.Files = []string{"sub/b.txt"}
	res := mustRun(t, s)
	if res.Files != 1 {
		t.Errorf("files = %d, want 1", res.Files)
	}
	if _, ok := read(t, remote, "a.txt"); ok {
		t.Error("fast path copied an unlisted file")
	}
}

func TestPreview(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	seedTree(t, local)
	write(t, remote, "only-remote.txt", "z")
	write(t, remote, "a.txt", "different content")
	j := job(local, remote, model.DirUpload, model.DeleteMirror, model.ConflictNewer)
	p, err := eng.Preview(context.Background(), spec(t, j))
	if err != nil {
		t.Fatal(err)
	}
	if p.Adds != 1 || p.Updates != 1 || p.Deletes != 1 {
		t.Errorf("adds/updates/deletes = %d/%d/%d, want 1/1/1 (%+v)", p.Adds, p.Updates, p.Deletes, p.Sample)
	}
	var paths []string
	for _, e := range p.Sample.Excluded {
		paths = append(paths, e.Path)
	}
	joined := strings.Join(paths, ",")
	for _, want := range []string{".git/", "proj/.claude/", "proj/node_modules/", ".DS_Store", "private/"} {
		if !strings.Contains(joined, want) {
			t.Errorf("excluded sample lacks %s: %s", want, joined)
		}
	}
	if _, ok := read(t, remote, "sub/b.txt"); ok {
		t.Error("preview must not copy")
	}
}

func TestTwoWayConflict(t *testing.T) {
	base := shortDir(t)
	local, remote := filepath.Join(base, "l"), filepath.Join(base, "r")
	write(t, local, "shared.txt", "v1")
	write(t, local, "notes/l.txt", "local")
	write(t, remote, "notes/r.txt", "remote")
	write(t, local, ".git/HEAD", "ref")
	j := job(local, remote, model.DirTwoWay, model.DeleteArchive, model.ConflictAsk)
	s := spec(t, j)
	s.Resync = true
	mustRun(t, s)
	if _, ok := read(t, local, "notes/r.txt"); !ok {
		t.Fatal("baseline did not bring remote file down")
	}
	if _, ok := read(t, remote, ".git/HEAD"); ok {
		t.Fatal(".git synced by bisync")
	}
	// Edits on both sides, plus a true conflict.
	time.Sleep(1100 * time.Millisecond)
	write(t, local, "notes/l.txt", "local v2")
	write(t, remote, "notes/r.txt", "remote v2")
	write(t, local, "shared.txt", "local edit")
	write(t, remote, "shared.txt", "remote edit!")
	res := mustRun(t, spec(t, j))
	if got, _ := read(t, remote, "notes/l.txt"); got != "local v2" {
		t.Errorf("local edit not propagated: %q", got)
	}
	if got, _ := read(t, local, "notes/r.txt"); got != "remote v2" {
		t.Errorf("remote edit not propagated: %q", got)
	}
	if len(res.Conflicts) != 1 {
		t.Fatalf("conflicts = %+v, want 1", res.Conflicts)
	}
	c := res.Conflicts[0]
	if c.Path != "shared.txt" || c.LocalCopy == "" || c.RemoteCopy == "" {
		t.Fatalf("bad conflict %+v", c)
	}
	if err := eng.ResolveConflict(context.Background(), j, c, "keepLocal"); err != nil {
		t.Fatal(err)
	}
	mustRun(t, spec(t, j))
	if got, _ := read(t, remote, "shared.txt"); got != "local edit" {
		t.Errorf("after keepLocal remote shared.txt = %q", got)
	}
	if _, ok := read(t, remote, c.RemoteCopy); ok {
		t.Error("loser copy should be gone after resolution")
	}
}

func TestBisyncLongPath(t *testing.T) {
	base := shortDir(t)
	long := filepath.Join(base, strings.Repeat("x", 120), strings.Repeat("y", 120))
	if err := os.MkdirAll(long, 0o755); err != nil {
		t.Skip("filesystem rejects long names")
	}
	j := job(long, long+"-remote", model.DirTwoWay, model.DeleteNever, model.ConflictNewer)
	s := spec(t, j)
	s.Resync = true
	res := eng.Run(context.Background(), s, nil)
	if res.Fail != FailPathTooLong {
		t.Fatalf("fail = %q (%v), want pathTooLong", res.Fail, res.Err)
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]string{
		"oauth2: cannot fetch token: invalid_grant":  FailAuth,
		"too many deletes":                           FailMaxDelete,
		"googleapi: Error 403: storageQuotaExceeded": FailQuota,
		"open /x: permission denied":                 FailPermission,
		"bisync aborted. Must run --resync":          FailNeedsResync,
		"something else":                             FailOther,
	}
	for msg, want := range cases {
		if got := Classify(errString(msg)); got != want {
			t.Errorf("Classify(%q) = %q, want %q", msg, got, want)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }
