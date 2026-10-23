// Package paths resolves the per-OS data directories and socket endpoint.
package paths

import (
	"fmt"
	"hash/crc32"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
)

// AppName is the human-facing directory name used on macOS and Windows.
const AppName = "PigmentDev rClone"

// Paths are the resolved locations used by the daemon.
type Paths struct {
	ConfigDir string // jobs.json, accounts.json, settings.json, rclone.conf
	DataDir   string // sqlite db, bisync workdirs, logs
	Socket    string // unix socket path or windows pipe name
	Override  bool   // PDRCLONE_HOME (or --home) is in effect
}

// Resolve computes paths honouring home (flag), PDRCLONE_HOME and
// PDRCLONE_SOCKET / socket (flag). Empty arguments mean "not given".
func Resolve(home, socket string) (Paths, error) {
	if home == "" {
		home = os.Getenv("PDRCLONE_HOME")
	}
	if socket == "" {
		socket = os.Getenv("PDRCLONE_SOCKET")
	}
	var p Paths
	if home != "" {
		abs, err := filepath.Abs(home)
		if err != nil {
			return p, err
		}
		p = Paths{ConfigDir: abs, DataDir: abs, Socket: defaultSocketUnder(abs), Override: true}
	} else {
		var err error
		p, err = osDefaults()
		if err != nil {
			return p, err
		}
	}
	if socket != "" {
		p.Socket = socket
	}
	return p, nil
}

// Ensure creates the directories with 0700 permissions.
func (p Paths) Ensure() error {
	dirs := []string{p.ConfigDir, p.DataDir}
	if runtime.GOOS != "windows" {
		dirs = append(dirs, filepath.Dir(p.Socket))
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return fmt.Errorf("create %s: %w", d, err)
		}
	}
	return nil
}

func defaultSocketUnder(dir string) string {
	if runtime.GOOS == "windows" {
		// One pipe per data dir so test/demo daemons never collide.
		return fmt.Sprintf("%s-%08x", pipeName(), crc32.ChecksumIEEE([]byte(dir)))
	}
	return filepath.Join(dir, "daemon.sock")
}

func pipeName() string {
	name := "user"
	if u, err := user.Current(); err == nil {
		name = filepath.Base(u.Username)
	}
	return `\\.\pipe\pdrclone-` + name
}

func osDefaults() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, err
	}
	switch runtime.GOOS {
	case "darwin":
		d := filepath.Join(home, "Library", "Application Support", AppName)
		return Paths{ConfigDir: d, DataDir: d, Socket: filepath.Join(d, "daemon.sock")}, nil
	case "windows":
		appData := os.Getenv("APPDATA")
		if appData == "" {
			appData = filepath.Join(home, "AppData", "Roaming")
		}
		d := filepath.Join(appData, AppName)
		return Paths{ConfigDir: d, DataDir: d, Socket: pipeName()}, nil
	default:
		cfg := os.Getenv("XDG_CONFIG_HOME")
		if cfg == "" {
			cfg = filepath.Join(home, ".config")
		}
		data := os.Getenv("XDG_DATA_HOME")
		if data == "" {
			data = filepath.Join(home, ".local", "share")
		}
		sock := filepath.Join(home, ".local", "state", "pdrclone", "daemon.sock")
		if rt := os.Getenv("XDG_RUNTIME_DIR"); rt != "" {
			sock = filepath.Join(rt, "pdrclone", "daemon.sock")
		}
		return Paths{ConfigDir: filepath.Join(cfg, "pdrclone"), DataDir: filepath.Join(data, "pdrclone"), Socket: sock}, nil
	}
}
