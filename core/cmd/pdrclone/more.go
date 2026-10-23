package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/platform"
)

func accountCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "account", Short: "Manage storage accounts"}
	list := &cobra.Command{Use: "list", Short: "List accounts", RunE: func(*cobra.Command, []string) error {
		var res struct {
			Accounts []model.Account `json:"accounts"`
		}
		if printed, err := callInto("accounts.list", nil, &res); err != nil || printed {
			return err
		}
		w := table()
		fmt.Fprintln(w, "ID\tNAME\tPROVIDER\tSTATUS\tUSED")
		for _, a := range res.Accounts {
			used := ""
			if a.Quota != nil && a.Quota.Used != nil {
				used = human(*a.Quota.Used)
				if a.Quota.Total != nil {
					used += " / " + human(*a.Quota.Total)
				}
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n", a.ID, a.Name, a.Provider, a.Status, used)
		}
		return w.Flush()
	}}
	var name string
	var fields []string
	add := &cobra.Command{Use: "add <provider>", Short: "Add an account (OAuth providers print a sign-in URL)", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		return addAccount(args[0], name, fields)
	}}
	add.Flags().StringVar(&name, "name", "", "display name")
	add.Flags().StringArrayVar(&fields, "field", nil, "provider option key=value (repeatable), e.g. --field host=nas.local")
	test := &cobra.Command{Use: "test <id>", Short: "Test an account connection", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		var r struct {
			OK        bool   `json:"ok"`
			Error     string `json:"error"`
			LatencyMs int64  `json:"latencyMs"`
		}
		if printed, err := callInto("accounts.test", map[string]any{"id": args[0]}, &r); err != nil || printed {
			return err
		}
		if !r.OK {
			return fmt.Errorf("connection failed: %s", r.Error)
		}
		fmt.Printf("ok (%d ms)\n", r.LatencyMs)
		return nil
	}}
	var force bool
	remove := &cobra.Command{Use: "remove <id>", Short: "Remove an account", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		if printed, err := callInto("accounts.remove", map[string]any{"id": args[0], "force": force}, nil); err != nil || printed {
			return err
		}
		fmt.Println("removed")
		return nil
	}}
	remove.Flags().BoolVar(&force, "force", false, "also delete jobs that use the account")
	providers := &cobra.Command{Use: "providers", Short: "List supported providers", RunE: func(*cobra.Command, []string) error {
		var res struct {
			Providers []model.Provider `json:"providers"`
		}
		if printed, err := callInto("accounts.providers", nil, &res); err != nil || printed {
			return err
		}
		w := table()
		fmt.Fprintln(w, "ID\tNAME\tAUTH\tCATEGORY")
		for _, p := range res.Providers {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", p.ID, p.Name, p.Auth, p.Category)
		}
		return w.Flush()
	}}
	cmd.AddCommand(list, add, test, remove, providers)
	return cmd
}

type addResult struct {
	State     string         `json:"state"`
	SessionID string         `json:"sessionId"`
	AuthURL   string         `json:"authUrl"`
	Account   *model.Account `json:"account"`
	Question  *struct {
		Name    string              `json:"name"`
		Label   string              `json:"label"`
		Help    string              `json:"help"`
		Type    string              `json:"type"`
		Options []model.FieldOption `json:"options"`
		Default any                 `json:"default"`
	} `json:"question"`
}

func addAccount(provider, name string, kv []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	c, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = c.Close() }()
	fields := map[string]any{}
	for _, f := range kv {
		k, v, ok := strings.Cut(f, "=")
		if !ok {
			return fmt.Errorf("--field %q: want key=value", f)
		}
		fields[k] = v
	}
	var r addResult
	if err := c.Call(ctx, "accounts.add.start", map[string]any{"provider": provider, "name": name, "fields": fields}, &r); err != nil {
		return err
	}
	in := bufio.NewReader(os.Stdin)
	shown := false
	for {
		switch r.State {
		case "done":
			fmt.Printf("account %s (%s) added\n", r.Account.ID, r.Account.Name)
			return nil
		case "needsOAuth":
			if !shown {
				fmt.Printf("Open this URL in a browser on this machine to sign in:\n\n  %s\n\nWaiting…\n", r.AuthURL)
				shown = true
			}
			time.Sleep(2 * time.Second)
			if err := c.Call(ctx, "accounts.add.continue", map[string]any{"sessionId": r.SessionID, "answer": nil}, &r); err != nil {
				return err
			}
		case "needsInput":
			q := r.Question
			fmt.Printf("\n%s\n%s\n", q.Label, q.Help)
			for _, o := range q.Options {
				fmt.Printf("  %s  %s\n", o.Value, o.Label)
			}
			fmt.Printf("[%v]> ", q.Default)
			line, _ := in.ReadString('\n')
			var answer any = strings.TrimSpace(line)
			if answer == "" {
				answer = nil
			}
			if err := c.Call(ctx, "accounts.add.continue", map[string]any{"sessionId": r.SessionID, "answer": answer}, &r); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unexpected state %q", r.State)
		}
	}
}

func logsCmd() *cobra.Command {
	var follow bool
	var job, level, search string
	var n int
	cmd := &cobra.Command{Use: "logs", Short: "Show daemon logs", RunE: func(*cobra.Command, []string) error {
		if job != "" {
			id, err := resolveJob(job)
			if err != nil {
				return err
			}
			job = id
		}
		var res struct {
			Lines []model.LogLine `json:"lines"`
		}
		raw, err := call("log.query", map[string]any{"jobId": job, "level": level, "search": search, "limit": n})
		if err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &res); err != nil {
			return err
		}
		slices.Reverse(res.Lines)
		for _, l := range res.Lines {
			printLine(l)
		}
		if !follow {
			return nil
		}
		ctx := context.Background()
		c, err := connect(ctx)
		if err != nil {
			return err
		}
		defer func() { _ = c.Close() }()
		if err := c.Call(ctx, "subscribe", map[string]any{"topics": []string{"log.line"}}, nil); err != nil {
			return err
		}
		for {
			select {
			case <-c.Done():
				return fmt.Errorf("daemon disconnected")
			case nt := <-c.Notify:
				if nt.Method != "log.line" {
					continue
				}
				var p struct {
					Line model.LogLine `json:"line"`
				}
				if json.Unmarshal(nt.Params, &p) != nil {
					continue
				}
				if job != "" && (p.Line.JobID == nil || *p.Line.JobID != job) {
					continue
				}
				printLine(p.Line)
			}
		}
	}}
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "stream new lines")
	cmd.Flags().StringVar(&job, "job", "", "only this job (id or name)")
	cmd.Flags().StringVar(&level, "level", "", "minimum level: debug|info|notice|warn|error")
	cmd.Flags().StringVar(&search, "search", "", "text or path to search for")
	cmd.Flags().IntVarP(&n, "lines", "n", 100, "number of lines")
	return cmd
}

func printLine(l model.LogLine) {
	if g.json {
		b, _ := json.Marshal(l)
		fmt.Println(string(b))
		return
	}
	path := ""
	if l.Path != nil {
		path = *l.Path + ": "
	}
	fmt.Printf("%s %-6s %s%s\n", l.TS.Local().Format("2006-01-02 15:04:05"), strings.ToUpper(l.Level), path, l.Msg)
}

func configCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "config", Short: "Export or import jobs and settings (no secrets)"}
	var out string
	export := &cobra.Command{Use: "export", Short: "Export jobs and settings as JSON", RunE: func(*cobra.Command, []string) error {
		raw, err := call("config.export", nil)
		if err != nil {
			return err
		}
		var v any
		_ = json.Unmarshal(raw, &v)
		b, _ := json.MarshalIndent(v, "", "  ")
		if out == "" {
			fmt.Println(string(b))
			return nil
		}
		return os.WriteFile(out, append(b, '\n'), 0o600)
	}}
	export.Flags().StringVarP(&out, "output", "o", "", "write to file instead of stdout")
	imp := &cobra.Command{Use: "import <file>", Short: "Import jobs and settings (accounts must already exist)", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		b, err := os.ReadFile(args[0])
		if err != nil {
			return err
		}
		var r struct {
			Imported int      `json:"imported"`
			Skipped  []string `json:"skipped"`
		}
		if printed, err := callInto("config.import", json.RawMessage(b), &r); err != nil || printed {
			return err
		}
		fmt.Printf("imported %d job(s)\n", r.Imported)
		for _, s := range r.Skipped {
			fmt.Println("  skipped:", s)
		}
		return nil
	}}
	cmd.AddCommand(export, imp)
	return cmd
}

// daemonBinary finds pdrcloned next to this executable or on PATH.
func daemonBinary() (string, error) {
	name := "pdrcloned"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), name)
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return exec.LookPath(name)
}

func daemonCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "daemon", Short: "Start, stop or install the daemon"}
	start := &cobra.Command{Use: "start", Short: "Start the daemon in the background", RunE: func(*cobra.Command, []string) error {
		if _, err := call("daemon.info", nil); err == nil {
			fmt.Println("already running")
			return nil
		}
		bin, err := daemonBinary()
		if err != nil {
			return fmt.Errorf("pdrcloned not found: %w", err)
		}
		args := []string{"run"}
		if g.home != "" {
			args = append(args, "--home", g.home)
		}
		if g.socket != "" {
			args = append(args, "--socket", g.socket)
		}
		c := exec.Command(bin, args...)
		detach(c)
		if err := c.Start(); err != nil {
			return err
		}
		_ = c.Process.Release()
		for range 50 {
			time.Sleep(100 * time.Millisecond)
			if _, err := call("daemon.info", nil); err == nil {
				fmt.Println("started")
				return nil
			}
		}
		return fmt.Errorf("daemon did not come up; run `pdrcloned run -v` to see why")
	}}
	stop := &cobra.Command{Use: "stop", Short: "Stop the daemon", RunE: func(*cobra.Command, []string) error {
		if _, err := call("daemon.shutdown", nil); err != nil {
			return err
		}
		fmt.Println("stopping")
		return nil
	}}
	install := &cobra.Command{Use: "install", Short: "Start the daemon at login", RunE: func(*cobra.Command, []string) error {
		bin, err := daemonBinary()
		if err != nil {
			return err
		}
		p, err := platform.Install(bin)
		if err != nil {
			return err
		}
		fmt.Println("installed:", p)
		return nil
	}}
	uninstall := &cobra.Command{Use: "uninstall", Short: "Remove the login service", RunE: func(*cobra.Command, []string) error {
		p, err := platform.Uninstall()
		if err != nil {
			return err
		}
		fmt.Println("removed:", p)
		return nil
	}}
	cmd.AddCommand(start, stop, install, uninstall)
	return cmd
}
