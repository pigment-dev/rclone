// Command pdrclone is the command-line client for the pdrcloned daemon.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/pigment-dev/rclone/core/internal/client"
	"github.com/pigment-dev/rclone/core/internal/paths"
	"github.com/pigment-dev/rclone/core/internal/version"
)

type globals struct {
	socket, home string
	json         bool
	timeout      time.Duration
}

var g globals

func main() {
	root := &cobra.Command{
		Use:           "pdrclone",
		Short:         "Control the PigmentDev rClone sync daemon",
		Version:       version.Version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	pf := root.PersistentFlags()
	pf.StringVar(&g.socket, "socket", "", "daemon socket (env PDRCLONE_SOCKET)")
	pf.StringVar(&g.home, "home", "", "data directory override (env PDRCLONE_HOME)")
	pf.BoolVar(&g.json, "json", false, "print raw JSON")
	pf.DurationVar(&g.timeout, "timeout", 2*time.Minute, "request timeout")
	root.AddCommand(statusCmd(), jobCmd(), accountCmd(), logsCmd(), configCmd(), daemonCmd())
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "pdrclone:", err)
		os.Exit(1)
	}
}

func socketPath() (string, error) {
	p, err := paths.Resolve(g.home, g.socket)
	if err != nil {
		return "", err
	}
	return p.Socket, nil
}

// connect dials the daemon.
func connect(ctx context.Context) (*client.Client, error) {
	s, err := socketPath()
	if err != nil {
		return nil, err
	}
	c, err := client.Dial(ctx, s, "cli")
	if err != nil {
		return nil, fmt.Errorf("cannot reach the daemon at %s (is it running? try `pdrclone daemon start`): %w", s, err)
	}
	return c, nil
}

// call performs one request and returns the raw result.
func call(method string, params any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), g.timeout)
	defer cancel()
	c, err := connect(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = c.Close() }()
	var out json.RawMessage
	if err := c.Call(ctx, method, params, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// callInto performs a request, prints JSON when --json, else decodes into v.
func callInto(method string, params, v any) (printed bool, err error) {
	raw, err := call(method, params)
	if err != nil {
		return false, err
	}
	if g.json {
		printJSON(raw)
		return true, nil
	}
	if v != nil {
		return false, json.Unmarshal(raw, v)
	}
	return false, nil
}

func printJSON(raw json.RawMessage) {
	var v any
	if json.Unmarshal(raw, &v) == nil {
		b, _ := json.MarshalIndent(v, "", "  ")
		fmt.Println(string(b))
		return
	}
	fmt.Println(string(raw))
}

func table() *tabwriter.Writer { return tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0) }

func human(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func deref(s *string, def string) string {
	if s == nil {
		return def
	}
	return *s
}

var errUsage = errors.New("invalid arguments")
