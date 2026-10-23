//go:build !windows

// Package ipc provides the local socket transport (unix socket / named pipe).
package ipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Listen creates the unix socket with mode 0600, removing a stale one.
func Listen(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if len(path) > 103 {
		return nil, fmt.Errorf("socket path too long (%d bytes, max 103): %s", len(path), path)
	}
	if _, err := os.Stat(path); err == nil {
		// Refuse to steal a live socket; remove a stale one.
		if c, err := net.DialTimeout("unix", path, 300*time.Millisecond); err == nil {
			_ = c.Close()
			return nil, errors.New("another daemon is already listening on " + path)
		}
		_ = os.Remove(path)
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = l.Close()
		return nil, err
	}
	return l, nil
}

// Dial connects to the daemon socket.
func Dial(ctx context.Context, path string) (net.Conn, error) {
	var d net.Dialer
	return d.DialContext(ctx, "unix", path)
}

// Cleanup removes the socket file.
func Cleanup(path string) { _ = os.Remove(path) }
