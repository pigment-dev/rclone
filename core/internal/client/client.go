// Package client is a small JSON-RPC client for the daemon socket.
package client

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"

	"github.com/pigment-dev/rclone/core/internal/api"
	"github.com/pigment-dev/rclone/core/internal/ipc"
	"github.com/pigment-dev/rclone/core/internal/version"
)

// Notification is a server push.
type Notification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     *int64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *api.Error      `json:"error"`
}

// Client is a connected, authenticated client.
type Client struct {
	nc      net.Conn
	nextID  atomic.Int64
	mu      sync.Mutex
	pending map[int64]chan response
	wmu     sync.Mutex
	Notify  chan Notification // buffered; dropped when full
	done    chan struct{}
	Hello   map[string]any
}

// Dial connects and performs hello.
func Dial(ctx context.Context, socket, clientName string) (*Client, error) {
	nc, err := ipc.Dial(ctx, socket)
	if err != nil {
		return nil, err
	}
	c := &Client{nc: nc, pending: map[int64]chan response{}, Notify: make(chan Notification, 1024), done: make(chan struct{})}
	go c.read()
	var hello map[string]any
	if err := c.Call(ctx, "hello", map[string]string{"client": clientName, "version": version.Version}, &hello); err != nil {
		_ = nc.Close()
		return nil, err
	}
	c.Hello = hello
	return c, nil
}

// Close closes the connection.
func (c *Client) Close() error { return c.nc.Close() }

// Done is closed when the connection drops.
func (c *Client) Done() <-chan struct{} { return c.done }

func (c *Client) read() {
	defer close(c.done)
	sc := bufio.NewScanner(c.nc)
	sc.Buffer(make([]byte, 64*1024), 16<<20)
	for sc.Scan() {
		var r response
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue
		}
		if r.ID == nil {
			if r.Method != "" {
				select {
				case c.Notify <- Notification{Method: r.Method, Params: r.Params}:
				default:
				}
			}
			continue
		}
		c.mu.Lock()
		ch := c.pending[*r.ID]
		delete(c.pending, *r.ID)
		c.mu.Unlock()
		if ch != nil {
			ch <- r
		}
	}
	c.mu.Lock()
	for id, ch := range c.pending {
		close(ch)
		delete(c.pending, id)
	}
	c.mu.Unlock()
}

// Call invokes method and decodes the result into out (may be nil).
func (c *Client) Call(ctx context.Context, method string, params, out any) error {
	id := c.nextID.Add(1)
	ch := make(chan response, 1)
	c.mu.Lock()
	c.pending[id] = ch
	c.mu.Unlock()
	if params == nil {
		params = map[string]any{}
	}
	b, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	if err != nil {
		return err
	}
	c.wmu.Lock()
	_, err = c.nc.Write(append(b, '\n'))
	c.wmu.Unlock()
	if err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return ctx.Err()
	case r, ok := <-ch:
		if !ok {
			return errors.New("connection closed")
		}
		if r.Error != nil {
			return r.Error
		}
		if out != nil && len(r.Result) > 0 {
			if err := json.Unmarshal(r.Result, out); err != nil {
				return fmt.Errorf("decode %s result: %w", method, err)
			}
		}
		return nil
	}
}
