package platform

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"text/template"
)

// Label is the launchd label / service identifier.
const Label = "com.pigmentdev.rclone.daemon"

// LaunchdPlist renders the per-user LaunchAgent plist for an absolute
// daemon path.
func LaunchdPlist(program string, args []string) string {
	var buf bytes.Buffer
	_ = plistTmpl.Execute(&buf, map[string]any{"Label": Label, "Program": program, "Args": args})
	return buf.String()
}

var plistTmpl = template.Must(template.New("plist").Parse(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{{.Label}}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{{.Program}}</string>
{{- range .Args}}
		<string>{{.}}</string>
{{- end}}
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
`))

// SystemdUnit renders the systemd user unit.
func SystemdUnit(program string) string {
	return fmt.Sprintf(`[Unit]
Description=PigmentDev rClone sync daemon
Documentation=https://pigment.dev/docs/rclone/
After=network-online.target

[Service]
Type=simple
ExecStart=%s run
Restart=on-failure
RestartSec=10
Nice=10
IOSchedulingClass=idle
MemoryHigh=300M

[Install]
WantedBy=default.target
`, program)
}

// ServicePaths returns where the service definition is written.
func ServicePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "LaunchAgents", Label+".plist"), nil
	case "linux":
		cfg := os.Getenv("XDG_CONFIG_HOME")
		if cfg == "" {
			cfg = filepath.Join(home, ".config")
		}
		return filepath.Join(cfg, "systemd", "user", "pdrcloned.service"), nil
	}
	return "", nil
}

// Install registers the daemon to start at login and starts it.
func Install(program string) (string, error) {
	program, err := filepath.Abs(program)
	if err != nil {
		return "", err
	}
	p, err := ServicePath()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "darwin":
		if err := writeFile(p, LaunchdPlist(program, []string{"run"})); err != nil {
			return "", err
		}
		uid := fmt.Sprint(os.Getuid())
		_ = exec.Command("launchctl", "bootout", "gui/"+uid+"/"+Label).Run()
		if out, err := exec.Command("launchctl", "bootstrap", "gui/"+uid, p).CombinedOutput(); err != nil {
			return p, fmt.Errorf("launchctl bootstrap: %v: %s", err, out)
		}
		return p, nil
	case "linux":
		if err := writeFile(p, SystemdUnit(program)); err != nil {
			return "", err
		}
		for _, args := range [][]string{{"--user", "daemon-reload"}, {"--user", "enable", "--now", "pdrcloned.service"}} {
			if out, err := exec.Command("systemctl", args...).CombinedOutput(); err != nil {
				return p, fmt.Errorf("systemctl %v: %v: %s", args, err, out)
			}
		}
		return p, nil
	case "windows":
		out, err := exec.Command("schtasks", "/Create", "/F", "/SC", "ONLOGON", "/RL", "LIMITED", "/TN", "PigmentDev rClone daemon", "/TR", fmt.Sprintf(`"%s" run`, program)).CombinedOutput()
		if err != nil {
			return "", fmt.Errorf("schtasks: %v: %s", err, out)
		}
		_ = exec.Command("schtasks", "/Run", "/TN", "PigmentDev rClone daemon").Run()
		return "task scheduler: PigmentDev rClone daemon", nil
	}
	return "", fmt.Errorf("install is not supported on %s", runtime.GOOS)
}

// Uninstall stops and unregisters the service.
func Uninstall() (string, error) {
	p, err := ServicePath()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), Label)).Run()
		return p, removeIfExists(p)
	case "linux":
		_ = exec.Command("systemctl", "--user", "disable", "--now", "pdrcloned.service").Run()
		err := removeIfExists(p)
		_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
		return p, err
	case "windows":
		out, err := exec.Command("schtasks", "/Delete", "/F", "/TN", "PigmentDev rClone daemon").CombinedOutput()
		if err != nil {
			return "", fmt.Errorf("schtasks: %v: %s", err, out)
		}
		return "task scheduler", nil
	}
	return "", fmt.Errorf("uninstall is not supported on %s", runtime.GOOS)
}

func writeFile(p, content string) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(content), 0o644)
}

func removeIfExists(p string) error {
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
