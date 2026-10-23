package filters

import (
	"bufio"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

type sourcedRule struct{ line, source string }

// maxGitignoreFiles caps how many nested .gitignore files are read.
const maxGitignoreFiles = 200

// skipWalk are directories never searched for nested .gitignore files.
var skipWalk = []string{".git", "node_modules", "vendor", ".venv", "venv", "Pods", "DerivedData", ".build", "target", "dist", "build"}

// gitignoreRules converts .gitignore files under root into rclone rules.
// Within a file git uses "last match wins" while rclone uses "first match
// wins", so each file's rules are emitted in reverse. Deeper files come
// first so they take precedence over their parents, like git.
func gitignoreRules(root string) []sourcedRule {
	var files []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && p != root && slices.Contains(skipWalk, d.Name()) {
			return filepath.SkipDir
		}
		if !d.IsDir() && d.Name() == ".gitignore" {
			files = append(files, p)
			if len(files) >= maxGitignoreFiles {
				return filepath.SkipAll
			}
		}
		return nil
	})
	// Deeper first.
	slices.SortStableFunc(files, func(a, b string) int {
		return strings.Count(b, string(filepath.Separator)) - strings.Count(a, string(filepath.Separator))
	})
	var out []sourcedRule
	for _, f := range files {
		relDir, _ := filepath.Rel(root, filepath.Dir(f))
		relDir = filepath.ToSlash(relDir)
		if relDir == "." {
			relDir = ""
		}
		src := ".gitignore"
		if relDir != "" {
			src = relDir + "/.gitignore"
		}
		lines := readLines(f)
		for i := len(lines) - 1; i >= 0; i-- {
			for _, r := range GitignoreLineToRules(lines[i], relDir) {
				out = append(out, sourcedRule{r, src})
			}
		}
	}
	return out
}

func readLines(p string) []string {
	f, err := os.Open(p)
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines
}

// GitignoreLineToRules converts one .gitignore line found in directory
// dir (slash-separated, relative to the job root, "" for the root) into
// rclone filter rules. Unsupported or blank lines return nil.
func GitignoreLineToRules(line, dir string) []string {
	line = strings.TrimRight(line, " \t")
	if line == "" || strings.HasPrefix(line, "#") {
		return nil
	}
	sign := "- "
	if strings.HasPrefix(line, "!") {
		sign = "+ "
		line = line[1:]
	}
	line = strings.TrimPrefix(line, `\`)
	dirOnly := strings.HasSuffix(line, "/")
	line = strings.TrimSuffix(line, "/")
	if line == "" {
		return nil
	}
	// A slash anywhere but the end anchors the pattern to dir.
	anchored := strings.Contains(line, "/")
	line = strings.TrimPrefix(line, "/")
	var pat string
	switch {
	case anchored && dir != "":
		pat = "/" + path.Join(dir, line)
	case anchored:
		pat = "/" + line
	case dir != "":
		pat = "/" + dir + "/**/" + line
	default:
		pat = line
	}
	if dirOnly {
		return []string{sign + pat + "/**"}
	}
	// Without a trailing slash the pattern can match a file or a folder.
	rules := []string{sign + pat + "/**", sign + pat}
	if dir != "" && !anchored {
		// "/dir/**/x" requires at least one level; add the direct child too.
		direct := "/" + dir + "/" + line
		rules = append(rules, sign+direct+"/**", sign+direct)
	}
	return rules
}
