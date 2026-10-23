// Package filters compiles job filter settings (presets, custom rules,
// .gitignore, size/age limits) into rclone filters and explains decisions.
package filters

// Preset is a named group of rclone filter rules.
type Preset struct {
	ID    string
	Label string
	Rules []string
}

// Presets is the canonical preset table (see docs/PROTOCOL.md).
var Presets = []Preset{
	{"vcs", "Version control", []string{"- .git/**", "- .svn/**", "- .hg/**", "- .bzr/**"}},
	{"ide", "IDE & agents", []string{"- .vscode/**", "- .idea/**", "- .claude/**", "- .cursor/**", "- .fleet/**", "- .zed/**"}},
	{"deps", "Dependencies", []string{"- node_modules/**", "- vendor/**", "- .venv/**", "- venv/**", "- __pycache__/**", "- .pnpm-store/**", "- Pods/**"}},
	{"build", "Build output", []string{"- dist/**", "- build/**", "- target/**", "- .next/**", "- .nuxt/**", "- out/**", "- DerivedData/**", "- .build/**"}},
	{"osjunk", "OS junk", []string{"- .DS_Store", "- ._*", "- Thumbs.db", "- desktop.ini", "- .Spotlight-V100/**", "- .Trashes/**", "- .fseventsd/**", "- Icon\r"}},
	{"caches", "Caches & temp", []string{"- .cache/**", "- *.tmp", "- *.swp", "- *~", "- .sass-cache/**"}},
	{"dotfolders", "All dot-folders", []string{"- .*/**"}},
	{"dotfiles", "All dot-files", []string{"- .*"}},
}

// ArchiveDir is the folder (relative to the destination root) holding
// archived deletions; it is always excluded from syncing.
const ArchiveDir = ".pdrclone-archive"

// alwaysRules are applied first and cannot be overridden.
var alwaysRules = []string{"- /" + ArchiveDir + "/**"}

// IsPreset reports whether id is a known preset.
func IsPreset(id string) bool {
	_, ok := presetByID(id)
	return ok
}

func presetByID(id string) (Preset, bool) {
	for _, p := range Presets {
		if p.ID == id {
			return p, true
		}
	}
	return Preset{}, false
}
