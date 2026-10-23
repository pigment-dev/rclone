package api

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"sync/atomic"
)

// Handler handles one method call.
type Handler func(ctx context.Context, c *Conn, params json.RawMessage) (any, error)

// DefaultTopics are subscribed automatically after hello.
var DefaultTopics = []string{"job.state", "job.progress", "overall.progress", "job.preview", "action.new", "action.updated", "daemon.health"}

const maxLine = 8 << 20

// Server dispatches requests and fans out notifications.
type Server struct {
	mu      sync.RWMutex
	methods map[string]Handler
	conns   map[*Conn]struct{}
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	// OnConnect/OnDisconnect are optional hooks (e.g. for client counts).
	OnDisconnect func(*Conn)
}

// NewServer returns an empty server. Register "hello" like any method;
// it is the only method allowed before authentication.
func NewServer() *Server {
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{methods: map[string]Handler{}, conns: map[*Conn]struct{}{}, ctx: ctx, cancel: cancel}
}

// Handle registers a method.
func (s *Server) Handle(method string, h Handler) {
	s.mu.Lock()
	s.methods[method] = h
	s.mu.Unlock()
}

// Serve accepts connections until l is closed.
func (s *Server) Serve(l net.Listener) error {
	for {
		nc, err := l.Accept()
		if err != nil {
			if s.ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		c := newConn(s, nc)
		s.mu.Lock()
		s.conns[c] = struct{}{}
		s.mu.Unlock()
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			c.serve()
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
			if s.OnDisconnect != nil {
				s.OnDisconnect(c)
			}
		}()
	}
}

// Close disconnects all clients.
func (s *Server) Close() {
	s.cancel()
	s.mu.RLock()
	for c := range s.conns {
		c.close()
	}
	s.mu.RUnlock()
	s.wg.Wait()
}

// Clients returns the number of authenticated connections.
func (s *Server) Clients() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for c := range s.conns {
		if c.authed.Load() {
			n++
		}
	}
	return n
}

// Publish sends a notification to every subscribed client.
func (s *Server) Publish(topic string, params any) {
	s.publish("", topic, params)
}

// PublishLatest sends a notification that replaces any not-yet-written
// notification with the same key (used for progress back-pressure).
func (s *Server) PublishLatest(key, topic string, params any) {
	s.publish(key, topic, params)
}

func (s *Server) publish(key, topic string, params any) {
	s.mu.RLock()
	var targets []*Conn
	for c := range s.conns {
		if c.authed.Load() && c.subscribed(topic) {
			targets = append(targets, c)
		}
	}
	s.mu.RUnlock()
	if len(targets) == 0 {
		return
	}
	b, err := json.Marshal(Notification{JSONRPC: "2.0", Method: topic, Params: params})
	if err != nil {
		return
	}
	for _, c := range targets {
		c.enqueue(key, b)
	}
}

// Conn is one client connection.
type Conn struct {
	srv    *Server
	nc     net.Conn
	authed atomic.Bool
	Client string // from hello

	subMu  sync.Mutex
	topics map[string]bool

	outMu     sync.Mutex
	queue     [][]byte
	latest    map[string][]byte
	latestOrd []string
	wake      chan struct{}
	closed    chan struct{}
	closeOnce sync.Once
}

const maxQueue = 4096

func newConn(s *Server, nc net.Conn) *Conn {
	return &Conn{srv: s, nc: nc, topics: map[string]bool{}, latest: map[string][]byte{}, wake: make(chan struct{}, 1), closed: make(chan struct{})}
}

// Authenticate marks the connection as past hello and subscribes defaults.
func (c *Conn) Authenticate(client string) {
	c.Client = client
	c.Subscribe(DefaultTopics)
	c.authed.Store(true)
}

// Subscribe adds topics.
func (c *Conn) Subscribe(topics []string) {
	c.subMu.Lock()
	for _, t := range topics {
		c.topics[t] = true
	}
	c.subMu.Unlock()
}

// Unsubscribe removes topics.
func (c *Conn) Unsubscribe(topics []string) {
	c.subMu.Lock()
	for _, t := range topics {
		delete(c.topics, t)
	}
	c.subMu.Unlock()
}

func (c *Conn) subscribed(t string) bool {
	c.subMu.Lock()
	defer c.subMu.Unlock()
	return c.topics[t]
}

func (c *Conn) close() {
	c.closeOnce.Do(func() {
		close(c.closed)
		_ = c.nc.Close()
	})
}

func (c *Conn) enqueue(key string, b []byte) {
	c.outMu.Lock()
	if key != "" {
		if _, ok := c.latest[key]; !ok {
			c.latestOrd = append(c.latestOrd, key)
		}
		c.latest[key] = b
	} else {
		if len(c.queue) >= maxQueue {
			c.outMu.Unlock()
			c.close() // client is not reading; drop it rather than grow forever
			return
		}
		c.queue = append(c.queue, b)
	}
	c.outMu.Unlock()
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

func (c *Conn) writer() {
	w := bufio.NewWriter(c.nc)
	for {
		select {
		case <-c.closed:
			return
		case <-c.wake:
		}
		c.outMu.Lock()
		q := c.queue
		c.queue = nil
		var lat [][]byte
		for _, k := range c.latestOrd {
			lat = append(lat, c.latest[k])
		}
		c.latest = map[string][]byte{}
		c.latestOrd = nil
		c.outMu.Unlock()
		for _, b := range append(q, lat...) {
			if _, err := w.Write(append(b, '\n')); err != nil {
				c.close()
				return
			}
		}
		if err := w.Flush(); err != nil {
			c.close()
			return
		}
	}
}

func (c *Conn) reply(id json.RawMessage, result any, err error) {
	if id == nil {
		return // notification from client: no reply
	}
	resp := Response{JSONRPC: "2.0", ID: id}
	if err != nil {
		var e *Error
		if !errors.As(err, &e) {
			e = &Error{Code: CodeInternal, Message: err.Error()}
		}
		resp.Error = e
	} else {
		if result == nil {
			result = OK
		}
		resp.Result = result
	}
	b, merr := json.Marshal(resp)
	if merr != nil {
		b, _ = json.Marshal(Response{JSONRPC: "2.0", ID: id, Error: &Error{Code: CodeInternal, Message: merr.Error()}})
	}
	c.enqueue("", b)
}

func (c *Conn) serve() {
	go c.writer()
	defer c.close()
	sc := bufio.NewScanner(c.nc)
	sc.Buffer(make([]byte, 64*1024), maxLine)
	var inflight sync.WaitGroup
	defer inflight.Wait()
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			c.reply(json.RawMessage("null"), nil, Errorf(CodeParse, "parse error: %v", err))
			continue
		}
		if req.JSONRPC != "2.0" || req.Method == "" {
			c.reply(orNull(req.ID), nil, Errorf(CodeInvalidRequest, "invalid request"))
			continue
		}
		c.srv.mu.RLock()
		h := c.srv.methods[req.Method]
		c.srv.mu.RUnlock()
		if req.Method == "hello" {
			// Synchronous so nothing else can race ahead of the handshake.
			if h == nil {
				c.reply(req.ID, nil, Errorf(CodeMethodNotFound, "method not found"))
				continue
			}
			res, err := h(c.srv.ctx, c, req.Params)
			c.reply(req.ID, res, err)
			continue
		}
		if !c.authed.Load() {
			c.reply(orNull(req.ID), nil, Errorf(CodeNoHello, "hello required first"))
			continue
		}
		if h == nil {
			c.reply(req.ID, nil, Errorf(CodeMethodNotFound, "method not found: %s", req.Method))
			continue
		}
		inflight.Add(1)
		go func(req Request) {
			defer inflight.Done()
			res, err := h(c.srv.ctx, c, req.Params)
			c.reply(req.ID, res, err)
		}(req)
	}
	// Let in-flight replies flush before closing.
	inflight.Wait()
	c.flushSoon()
}

// flushSoon wakes the writer one last time so queued replies are written.
func (c *Conn) flushSoon() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

func orNull(id json.RawMessage) json.RawMessage {
	if id == nil {
		return json.RawMessage("null")
	}
	return id
}
