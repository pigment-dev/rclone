package filters

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/filter"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// compiledRule is one rclone rule with its origin, for explanations.
type compiledRule struct {
	line    string // "- .git/**"
	include bool
	re      *regexp.Regexp
	source  string // "preset vcs", "custom rule", ".gitignore"
}

// Compiled is a job's filter, ready to hand to rclone.
type Compiled struct {
	rules            []compiledRule
	maxSize          int64 // -1 = off
	minAge           time.Duration
	excludeIfPresent []string
	skipSymlinks     bool
}

// Options configures compilation.
type Options struct {
	// LocalRoot is used to read .gitignore files when RespectGitignore is set.
	LocalRoot string
}

// Compile builds the filter for f. Order: built-in archive exclusion,
// custom rules, .gitignore rules, presets (first match wins in rclone).
func Compile(f model.Filters, opt Options) (*Compiled, error) {
	c := &Compiled{maxSize: -1, skipSymlinks: f.SkipSymlinks}
	add := func(line, source string) error {
		include := strings.HasPrefix(line, "+ ")
		if !include && !strings.HasPrefix(line, "- ") {
			return fmt.Errorf("malformed rule %q", line)
		}
		re, err := filter.GlobPathToRegexp(line[2:], false)
		if err != nil {
			return fmt.Errorf("rule %q: %w", line, err)
		}
		c.rules = append(c.rules, compiledRule{line: line, include: include, re: re, source: source})
		return nil
	}
	for _, r := range alwaysRules {
		if err := add(r, "built-in"); err != nil {
			return nil, err
		}
	}
	for _, r := range f.Rules {
		prefix := "- "
		if r.Kind == "include" {
			prefix = "+ "
		}
		if err := add(prefix+strings.TrimSpace(r.Pattern), "custom rule"); err != nil {
			return nil, err
		}
	}
	if f.RespectGitignore && opt.LocalRoot != "" {
		for _, gr := range gitignoreRules(opt.LocalRoot) {
			if err := add(gr.line, gr.source); err != nil {
				continue // ignore patterns rclone cannot express
			}
		}
	}
	for _, id := range f.Presets {
		p, ok := presetByID(id)
		if !ok {
			return nil, fmt.Errorf("unknown preset %q", id)
		}
		for _, r := range p.Rules {
			if err := add(r, "preset "+id); err != nil {
				return nil, err
			}
		}
	}
	if f.MaxSizeMB != nil && *f.MaxSizeMB > 0 {
		c.maxSize = int64(*f.MaxSizeMB) * 1024 * 1024
	}
	if f.MinAgeSec > 0 {
		c.minAge = time.Duration(f.MinAgeSec) * time.Second
	}
	c.excludeIfPresent = append(c.excludeIfPresent, f.ExcludeIfPresent...)
	return c, nil
}

// RuleLines returns the rclone filter rules in order.
func (c *Compiled) RuleLines() []string {
	out := make([]string, len(c.rules))
	for i, r := range c.rules {
		out[i] = r.line
	}
	return out
}

// SkipSymlinks reports whether symlinks should be skipped.
func (c *Compiled) SkipSymlinks() bool { return c.skipSymlinks }

// RcloneOptions returns rclone filter options. withAge=false drops the
// min-age limit (used by previews and listings).
func (c *Compiled) RcloneOptions(withAge bool) filter.Options {
	opt := filter.Opt
	opt.RulesOpt = filter.RulesOpt{FilterRule: c.RuleLines()}
	opt.ExcludeFile = append([]string(nil), c.excludeIfPresent...)
	opt.MinSize = -1
	opt.MaxSize = -1
	opt.MinAge = fs.DurationOff
	opt.MaxAge = fs.DurationOff
	opt.FilesFrom = nil
	if c.maxSize >= 0 {
		opt.MaxSize = fs.SizeSuffix(c.maxSize)
	}
	if withAge && c.minAge > 0 {
		opt.MinAge = fs.Duration(c.minAge)
	}
	return opt
}

// Rclone builds an rclone *filter.Filter.
func (c *Compiled) Rclone(withAge bool) (*filter.Filter, error) {
	opt := c.RcloneOptions(withAge)
	return filter.NewFilter(&opt)
}

// Anchored reports whether any user or preset rule is anchored to the job
// root ("/name/…"). Such rules only make sense against the whole tree, so the
// engine doesn't split those jobs into per-folder runs.
func (c *Compiled) Anchored() bool {
	for _, r := range c.rules {
		if r.source != "built-in" && strings.HasPrefix(r.line[2:], "/") {
			return true
		}
	}
	return false
}

// MatchPath returns the first rule matching the slash-separated relative
// path, or nil if none matches (included by default).
func (c *Compiled) MatchPath(rel string) (include bool, rule *compiledRule) {
	rel = strings.TrimPrefix(path.Clean("/"+filepath.ToSlash(rel)), "/")
	for i := range c.rules {
		if c.rules[i].re.MatchString(rel) {
			return c.rules[i].include, &c.rules[i]
		}
	}
	return true, nil
}

// ExcludesDir reports whether a directory (relative path) is pruned by an
// exclude rule, i.e. everything below it is excluded. Used by the watcher
// and the preview walker to avoid descending into e.g. node_modules.
func (c *Compiled) ExcludesDir(rel string) (bool, string) {
	rel = strings.Trim(filepath.ToSlash(rel), "/")
	if rel == "" {
		return false, ""
	}
	// An include rule that may match something below this dir keeps it.
	probe := rel + "/\x00probe"
	for _, r := range c.rules {
		if r.include && (r.re.MatchString(probe) || includeReachesInto(r.line[2:], rel)) {
			return false, ""
		}
		if !r.include && r.re.MatchString(probe) && strings.HasSuffix(r.line, "/**") {
			return true, r.label()
		}
	}
	return false, ""
}

// includeReachesInto is a conservative check that an include glob may
// match a path under dir (compared segment by segment).
func includeReachesInto(glob, dir string) bool {
	anchored := strings.HasPrefix(glob, "/")
	gs := strings.Split(strings.TrimPrefix(glob, "/"), "/")
	ds := strings.Split(dir, "/")
	if len(gs) < 2 {
		return false // a bare name matches files, not folder contents
	}
	starts := []int{0}
	if !anchored {
		starts = starts[:0]
		for i := range ds {
			starts = append(starts, i)
		}
	}
	for _, start := range starts {
		if segmentsMayMatch(gs, ds[start:]) {
			return true
		}
	}
	return false
}

func segmentsMayMatch(gs, ds []string) bool {
	for i, d := range ds {
		if i >= len(gs)-1 {
			return gs[len(gs)-1] == "**"
		}
		if gs[i] == "**" {
			return true
		}
		if ok, _ := path.Match(gs[i], d); !ok {
			return false
		}
	}
	return true
}

func (r *compiledRule) label() string {
	return fmt.Sprintf("%s (%s)", strings.ReplaceAll(r.line, "\r", `\r`), r.source)
}

// Explain reports whether rel (relative to the local root) would be synced
// and which rule decided. localRoot may be "" to skip on-disk checks
// (size, age, exclude-if-present markers).
func (c *Compiled) Explain(localRoot, rel string) (bool, *string) {
	rel = strings.Trim(filepath.ToSlash(rel), "/")
	// Directories excluded higher up win, as rclone never descends into them.
	parts := strings.Split(rel, "/")
	for i := 1; i < len(parts); i++ {
		dir := strings.Join(parts[:i], "/")
		if ex, why := c.ExcludesDir(dir); ex {
			return false, &why
		}
		if localRoot != "" {
			for _, marker := range c.excludeIfPresent {
				if _, err := os.Lstat(filepath.Join(localRoot, filepath.FromSlash(dir), marker)); err == nil {
					why := fmt.Sprintf("folder %s contains %s (exclude-if-present)", dir, marker)
					return false, &why
				}
			}
		}
	}
	if localRoot != "" {
		for _, marker := range c.excludeIfPresent {
			if _, err := os.Lstat(filepath.Join(localRoot, marker)); err == nil {
				why := fmt.Sprintf("job folder contains %s (exclude-if-present)", marker)
				return false, &why
			}
		}
	}
	var fi os.FileInfo
	if localRoot != "" {
		fi, _ = os.Lstat(filepath.Join(localRoot, filepath.FromSlash(rel)))
	}
	return c.ExplainEntry(rel, fi)
}

// DirMarker returns the exclude-if-present marker found in dir, if any.
func (c *Compiled) DirMarker(dir string) string {
	for _, marker := range c.excludeIfPresent {
		if _, err := os.Lstat(filepath.Join(dir, marker)); err == nil {
			return marker
		}
	}
	return ""
}

// ExplainEntry evaluates one file without looking at its ancestors. fi may
// be nil when the file is not on disk.
func (c *Compiled) ExplainEntry(rel string, fi os.FileInfo) (bool, *string) {
	include, rule := c.MatchPath(rel)
	if rule != nil {
		l := rule.label()
		return include, &l
	}
	if fi != nil {
		if c.skipSymlinks && fi.Mode()&os.ModeSymlink != 0 {
			why := "symlink (skipSymlinks)"
			return false, &why
		}
		if !fi.IsDir() && c.maxSize >= 0 && fi.Size() > c.maxSize {
			why := fmt.Sprintf("larger than %d MB (maxSizeMB)", c.maxSize/1024/1024)
			return false, &why
		}
		if !fi.IsDir() && c.minAge > 0 && time.Since(fi.ModTime()) < c.minAge {
			why := fmt.Sprintf("modified less than %s ago (minAgeSec)", c.minAge)
			return false, &why
		}
	}
	return true, nil
}
