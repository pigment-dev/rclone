// Command pdrcloned is the PigmentDev rClone sync daemon.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/pigment-dev/rclone/core/internal/daemon"
	"github.com/pigment-dev/rclone/core/internal/demo"
	"github.com/pigment-dev/rclone/core/internal/paths"
	"github.com/pigment-dev/rclone/core/internal/platform"
	"github.com/pigment-dev/rclone/core/internal/version"
)

type flags struct {
	socket, home, logLevel string
	demo, verbose          bool
	memoryMB               int
}

func main() {
	var f flags
	root := &cobra.Command{
		Use:           "pdrcloned",
		Short:         "PigmentDev rClone sync daemon",
		Version:       version.Version,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE:          func(cmd *cobra.Command, _ []string) error { return run(f) },
	}
	pf := root.PersistentFlags()
	pf.StringVar(&f.socket, "socket", "", "socket path (or named pipe on Windows); env PDRCLONE_SOCKET")
	pf.StringVar(&f.home, "home", "", "data directory override; env PDRCLONE_HOME")
	pf.BoolVar(&f.demo, "demo", false, "run with simulated accounts, jobs and progress (no network, temp data dir)")
	pf.StringVar(&f.logLevel, "log-level", "", "debug|info|notice (default from settings)")
	pf.BoolVarP(&f.verbose, "verbose", "v", false, "mirror log lines to stderr")
	pf.IntVar(&f.memoryMB, "memory-limit", 256, "soft memory limit in MiB (GOMEMLIMIT)")
	root.AddCommand(
		&cobra.Command{Use: "run", Short: "Run the daemon in the foreground (default)", RunE: func(*cobra.Command, []string) error { return run(f) }},
		&cobra.Command{Use: "install", Short: "Start the daemon at login (launchd / systemd user unit / Task Scheduler)", RunE: func(*cobra.Command, []string) error {
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			p, err := platform.Install(exe)
			if err != nil {
				return err
			}
			fmt.Println("installed:", p)
			return nil
		}},
		&cobra.Command{Use: "uninstall", Short: "Stop and remove the login service", RunE: func(*cobra.Command, []string) error {
			p, err := platform.Uninstall()
			if err != nil {
				return err
			}
			fmt.Println("removed:", p)
			return nil
		}},
	)
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "pdrcloned:", err)
		os.Exit(1)
	}
}

func run(f flags) error {
	if f.memoryMB > 0 && os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(int64(f.memoryMB) << 20)
	}
	var tmpHome string
	if f.demo && f.home == "" && os.Getenv("PDRCLONE_HOME") == "" {
		dir, err := os.MkdirTemp("", "pdr-demo")
		if err != nil {
			return err
		}
		tmpHome, f.home = dir, dir
		defer func() { _ = os.RemoveAll(tmpHome) }()
	}
	p, err := paths.Resolve(f.home, f.socket)
	if err != nil {
		return err
	}
	if f.demo && !p.Override {
		return fmt.Errorf("--demo refuses to use the real data directory; pass --home or unset it")
	}
	opt := daemon.Options{Paths: p, LogLevel: f.logLevel, Demo: f.demo, Stderr: f.verbose, SelfDetect: !f.demo}
	var eng *demo.Engine
	if f.demo {
		if err := demo.Seed(p); err != nil {
			return fmt.Errorf("seed demo data: %w", err)
		}
		eng = demo.NewEngine()
		opt.Engine, opt.Flow = eng, demo.NewFlow()
	}
	d, err := daemon.New(opt)
	if err != nil {
		return err
	}
	if f.demo {
		d.SetSystemState(demo.SystemState())
	}
	if err := d.Start(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if f.demo {
		go demo.Loop(ctx, d, eng)
		fmt.Fprintf(os.Stderr, "pdrcloned demo mode: data %s, socket %s\n", filepath.Clean(p.DataDir), p.Socket)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case <-sig:
		d.Stop()
	case <-d.Done():
	}
	return nil
}
