package filters

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/pigment-dev/rclone/core/internal/model"
)

func compile(t *testing.T, f model.Filters, root string) *Compiled {
	t.Helper()
	c, err := Compile(f, Options{LocalRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestPresetsExclude(t *testing.T) {
	c := compile(t, model.Filters{Presets: []string{"vcs", "ide", "deps", "build", "osjunk", "caches"}}, "")
	excluded := []string{
		".git/config", "src/app/.git/HEAD", ".claude/settings.json", "a/b/.claude/x", ".vscode/settings.json",
		"node_modules/react/index.js", "web/node_modules/x.js", "venv/bin/python", "__pycache__/m.pyc",
		"dist/app.js", ".next/cache/x", "DerivedData/Build/x", ".DS_Store", "photos/.DS_Store", "._resource",
		"Thumbs.db", "Icon\r", ".cache/pip/x", "notes.swp", "draft.tmp", "file~",
	}
	for _, p := range excluded {
		if ok, rule := c.Explain("", p); ok {
			t.Errorf("%q should be excluded", p)
		} else if rule == nil {
			t.Errorf("%q excluded without a rule", p)
		}
	}
	included := []string{"main.go", "src/git.go", "docs/claude.md", "build.gradle", "vendor.txt", "my.git.notes", "Icon.png"}
	for _, p := range included {
		if ok, rule := c.Explain("", p); !ok {
			t.Errorf("%q should be included (rule %v)", p, *rule)
		}
	}
}

func TestDotfoldersAndDotfiles(t *testing.T) {
	c := compile(t, model.Filters{Presets: []string{"dotfolders"}}, "")
	if ok, _ := c.Explain("", ".config/app.toml"); ok {
		t.Error(".config/ should be excluded by dotfolders")
	}
	if ok, _ := c.Explain("", ".env"); !ok {
		t.Error(".env is a file; dotfolders must keep it")
	}
	c = compile(t, model.Filters{Presets: []string{"dotfiles"}}, "")
	if ok, _ := c.Explain("", "app/.env"); ok {
		t.Error(".env should be excluded by dotfiles")
	}
}

func TestIncludeOverridesPreset(t *testing.T) {
	f := model.Filters{
		Presets: []string{"dotfolders", "build"},
		Rules:   []model.Rule{{Kind: "include", Pattern: ".github/**"}, {Kind: "include", Pattern: "/dist/keep.js"}, {Kind: "exclude", Pattern: "*.log"}},
	}
	c := compile(t, f, "")
	for _, p := range []string{".github/workflows/ci.yml", "dist/keep.js"} {
		if ok, rule := c.Explain("", p); !ok {
			t.Errorf("%q should be included by an include rule, got %v", p, *rule)
		}
	}
	if ok, _ := c.Explain("", "dist/other.js"); ok {
		t.Error("dist/other.js should still be excluded")
	}
	if ok, rule := c.Explain("", "logs/app.log"); ok || !strings.Contains(*rule, "custom rule") {
		t.Errorf("*.log should be excluded by the custom rule, got %v %v", ok, rule)
	}
	if ex, _ := c.ExcludesDir(".github"); ex {
		t.Error(".github must be traversed because of the include rule")
	}
	if ex, why := c.ExcludesDir(".idea"); !ex || !strings.Contains(why, "dotfolders") {
		t.Errorf(".idea should be pruned by dotfolders: %v %q", ex, why)
	}
}

func TestArchiveAlwaysExcluded(t *testing.T) {
	c := compile(t, model.Filters{Rules: []model.Rule{{Kind: "include", Pattern: "**"}}}, "")
	if ok, _ := c.Explain("", ArchiveDir+"/2026-01-01/a.txt"); ok {
		t.Error("archive folder must never sync")
	}
}

func TestRcloneFilterAgrees(t *testing.T) {
	c := compile(t, model.Filters{Presets: []string{"vcs", "deps"}, Rules: []model.Rule{{Kind: "include", Pattern: "node_modules/keep/**"}}}, "")
	fi, err := c.Rclone(false)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"a.go", ".git/x", "node_modules/x.js", "node_modules/keep/a.js"} {
		mine, _ := c.MatchPath(p)
		if got := fi.IncludeRemote(p); got != mine {
			t.Errorf("%s: rclone=%v mine=%v", p, got, mine)
		}
	}
}

func TestExcludeIfPresentAndSize(t *testing.T) {
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "private"), 0o755))
	must(os.WriteFile(filepath.Join(root, "private", ".nosync"), nil, 0o644))
	must(os.WriteFile(filepath.Join(root, "private", "a.txt"), []byte("x"), 0o644))
	must(os.WriteFile(filepath.Join(root, "big.bin"), make([]byte, 2<<20), 0o644))
	c := compile(t, model.Filters{ExcludeIfPresent: []string{".nosync"}, MaxSizeMB: model.Ptr(1)}, root)
	if ok, rule := c.Explain(root, "private/a.txt"); ok || !strings.Contains(*rule, ".nosync") {
		t.Errorf("private/a.txt should be excluded by .nosync: %v %v", ok, rule)
	}
	if ok, rule := c.Explain(root, "big.bin"); ok || !strings.Contains(*rule, "maxSizeMB") {
		t.Errorf("big.bin should be excluded by size: %v %v", ok, rule)
	}
}

func TestGitignore(t *testing.T) {
	cases := []struct {
		line, dir string
		want      []string
	}{
		{"*.log", "", []string{"- *.log/**", "- *.log"}},
		{"build/", "", []string{"- build/**"}},
		{"/secret.txt", "", []string{"- /secret.txt/**", "- /secret.txt"}},
		{"!keep.log", "", []string{"+ keep.log/**", "+ keep.log"}},
		{"tmp/", "web", []string{"- /web/**/tmp/**"}},
		{"# comment", "", nil},
		{"", "", nil},
	}
	for _, tc := range cases {
		got := GitignoreLineToRules(tc.line, tc.dir)
		if !slices.Equal(got, tc.want) {
			t.Errorf("%q in %q: got %v want %v", tc.line, tc.dir, got, tc.want)
		}
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("*.log\n!important.log\ncoverage/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := compile(t, model.Filters{RespectGitignore: true}, root)
	if ok, _ := c.Explain("", "debug.log"); ok {
		t.Error("debug.log should be ignored via .gitignore")
	}
	if ok, _ := c.Explain("", "important.log"); !ok {
		t.Error("important.log is re-included by !important.log")
	}
	if ok, _ := c.Explain("", "coverage/index.html"); ok {
		t.Error("coverage/ should be ignored")
	}
}

func TestUnknownPreset(t *testing.T) {
	if _, err := Compile(model.Filters{Presets: []string{"nope"}}, Options{}); err == nil {
		t.Error("unknown preset accepted")
	}
}
