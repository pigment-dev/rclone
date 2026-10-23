//go:build windows

// Package ipc provides the local socket transport (unix socket / named pipe).
package ipc

import (
	"context"
	"net"

	winio "github.com/Microsoft/go-winio"
)

// Listen creates the named pipe, accessible only to the current user
// (owner + SYSTEM).
func Listen(path string) (net.Listener, error) {
	return winio.ListenPipe(path, &winio.PipeConfig{
		SecurityDescriptor: "D:P(A;;GA;;;OW)(A;;GA;;;SY)",
		MessageMode:        false,
		InputBufferSize:    65536,
		OutputBufferSize:   65536,
	})
}

// Dial connects to the daemon pipe.
func Dial(ctx context.Context, path string) (net.Conn, error) {
	return winio.DialPipeContext(ctx, path)
}

// Cleanup is a no-op for named pipes.
func Cleanup(string) {}
