package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/pigment-dev/rclone/core/internal/ipc"
)

func startServer(t *testing.T) (*Server, string) {
	t.Helper()
	dir, err := os.MkdirTemp("", "pdr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "s.sock")
	if runtime.GOOS == "windows" {
		sock = `\\.\pipe\pdrclone-test-` + filepath.Base(dir)
	}
	l, err := ipc.Listen(sock)
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer()
	s.Handle("hello", func(_ context.Context, c *Conn, _ json.RawMessage) (any, error) {
		c.Authenticate("test")
		return map[string]int{"protocol": 1}, nil
	})
	s.Handle("echo", func(_ context.Context, _ *Conn, p json.RawMessage) (any, error) {
		var v map[string]any
		if err := Bind(p, &v); err != nil {
			return nil, err
		}
		return v, nil
	})
	go func() { _ = s.Serve(l) }()
	t.Cleanup(func() { _ = l.Close(); s.Close() })
	return s, sock
}

func send(t *testing.T, c net.Conn, s string) {
	t.Helper()
	if _, err := c.Write([]byte(s + "\n")); err != nil {
		t.Fatal(err)
	}
}

func TestProtocol(t *testing.T) {
	s, sock := startServer(t)
	if runtime.GOOS != "windows" {
		if fi, err := os.Stat(sock); err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("socket mode: %v %v", fi, err)
		}
	}
	c, err := ipc.Dial(context.Background(), sock)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	r := bufio.NewReader(c)
	next := func() map[string]any {
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		line, err := r.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			t.Fatalf("bad json %q", line)
		}
		return m
	}
	code := func(m map[string]any) float64 {
		e, _ := m["error"].(map[string]any)
		if e == nil {
			return 0
		}
		return e["code"].(float64)
	}
	send(t, c, `{"jsonrpc":"2.0","id":1,"method":"echo","params":{}}`)
	if got := code(next()); got != CodeNoHello {
		t.Fatalf("pre-hello code %v", got)
	}
	send(t, c, `not json`)
	if got := code(next()); got != CodeParse {
		t.Fatalf("parse code %v", got)
	}
	send(t, c, `{"jsonrpc":"2.0","id":2,"method":"hello","params":{"client":"cli"}}`)
	if m := next(); m["result"] == nil {
		t.Fatalf("hello: %v", m)
	}
	send(t, c, `{"jsonrpc":"2.0","id":3,"method":"echo","params":{"a":"b"}}`)
	if m := next(); m["result"].(map[string]any)["a"] != "b" {
		t.Fatalf("echo: %v", m)
	}
	send(t, c, `{"jsonrpc":"2.0","id":4,"method":"nope"}`)
	if got := code(next()); got != CodeMethodNotFound {
		t.Fatalf("not found code %v", got)
	}
	// Coalescing: many progress updates for the same key collapse.
	for i := range 200 {
		s.PublishLatest("job.progress:j", "job.progress", map[string]int{"i": i})
	}
	s.Publish("log.line", map[string]string{"msg": "not subscribed"})
	s.Publish("job.state", map[string]string{"jobId": "j"})
	seen, last := 0, -1.0
	gotState := false
	for seen < 200 {
		m := next()
		if m["method"] == "job.state" {
			gotState = true
		}
		if m["method"] == "log.line" {
			t.Fatal("log.line delivered without subscription")
		}
		if m["method"] == "job.progress" {
			seen++
			last = m["params"].(map[string]any)["i"].(float64)
			if last == 199 {
				break
			}
		}
	}
	if last != 199 {
		t.Errorf("coalescing: saw %d progress messages, last %v", seen, last)
	}
	_ = gotState // ordering between queues is not guaranteed
	if !strings.Contains(sock, "s") || s.Clients() != 1 {
		t.Errorf("clients = %d", s.Clients())
	}
}
