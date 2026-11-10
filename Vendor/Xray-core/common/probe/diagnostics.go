// Package probe records endpoint-free diagnostics only for temporary probes.
package probe

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	c "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/flightrecorder"
)

type Event struct {
	Stage     string `json:"stage"`
	Role      string `json:"role,omitempty"`
	Session   uint32 `json:"session,omitempty"`
	ElapsedMS int64  `json:"elapsedMs"`
	Code      string `json:"code,omitempty"`
	Status    int    `json:"status,omitempty"`
	Reused    bool   `json:"reused,omitempty"`
	Verified  *bool  `json:"verified,omitempty"`
}

type Recorder struct {
	mu          sync.Mutex
	start       time.Time
	lifetime    context.Context
	id          uint64
	target      string
	events      []Event
	active      int
	sealed      bool
	changed     chan struct{}
	connections []net.Conn
}

type contextKey struct{}
type dnsContextKey struct{}

var nextID atomic.Uint64

func New(ctx context.Context, target string) (context.Context, *Recorder) {
	r := &Recorder{start: time.Now(), lifetime: ctx, id: nextID.Add(1), target: target, changed: make(chan struct{}, 1)}
	return context.WithValue(ctx, contextKey{}, r), r
}

func FromContext(ctx context.Context) *Recorder {
	r, _ := ctx.Value(contextKey{}).(*Recorder)
	return r
}

func IsTarget(ctx context.Context, domain string) bool {
	r := FromContext(ctx)
	return r != nil && domain == r.target
}

// DNS dispatch deliberately detaches from the request; retain only probe metadata.
func DNSContext(detached, parent context.Context) context.Context {
	if r := FromContext(parent); r != nil {
		detached = context.WithValue(detached, contextKey{}, r)
		detached = context.WithValue(detached, dnsContextKey{}, true)
	}
	return detached
}

// RequestContext retains cancellation for probes without changing tunnel streams.
func RequestContext(ctx context.Context) context.Context {
	if r := FromContext(ctx); r != nil {
		return lifetimeContext{Context: ctx, lifetime: r.lifetime}
	}
	return context.WithoutCancel(ctx)
}

// AfterEnd calls f once the probe that owns ctx ends, for work that net/http
// detached from its request's cancellation; stop is context.AfterFunc's.
func AfterEnd(ctx context.Context, f func()) (stop func() bool) {
	if r := FromContext(ctx); r != nil {
		return context.AfterFunc(r.lifetime, f)
	}
	return func() bool { return false }
}

type lifetimeContext struct {
	context.Context
	lifetime context.Context
}

func (c lifetimeContext) Deadline() (time.Time, bool) { return c.lifetime.Deadline() }
func (c lifetimeContext) Done() <-chan struct{}       { return c.lifetime.Done() }
func (c lifetimeContext) Err() error                  { return c.lifetime.Err() }

func Code(err error) string {
	if err == nil {
		return "ok"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if errors.Is(err, io.EOF) {
		return "eof"
	}
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return "unexpected_eof"
	}
	if errors.Is(err, io.ErrClosedPipe) {
		return "closed_pipe"
	}
	var e net.Error
	if errors.As(err, &e) && e.Timeout() {
		return "timeout"
	}
	return "failed"
}

func Emit(ctx context.Context, stage string, err error, status int) {
	Record(ctx, Event{Stage: stage, Code: Code(err), Status: status})
}

func Record(ctx context.Context, event Event) {
	if flightrecorder.Enabled() {
		values := map[string]int64{"status": int64(event.Status)}
		if event.Reused {
			values["reused"] = 1
		}
		if event.Verified != nil {
			if *event.Verified {
				values["verified"] = 1
			} else {
				values["verified"] = 0
			}
		}
		flightrecorder.Record(flightrecorder.Event{Name: event.Stage, Code: event.Code, Session: uint32(c.IDFromContext(ctx)), Connection: flightrecorder.Connection(ctx), Values: values})
	}
	r := FromContext(ctx)
	if r == nil {
		return
	}
	event.Session = uint32(c.IDFromContext(ctx))
	event.Role = "target"
	if dns, _ := ctx.Value(dnsContextKey{}).(bool); dns {
		event.Role = "dns"
	}
	event.ElapsedMS = time.Since(r.start).Milliseconds()
	r.mu.Lock()
	defer r.mu.Unlock()
	// ponytail: bounded trace, use a streaming sink if probes need more events.
	if len(r.events) < 256 {
		r.events = append(r.events, event)
	}
}

func (r *Recorder) Snapshot() (uint64, []Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.id, append([]Event(nil), r.events...)
}

// Begin admits transport work until cleanup seals this probe.
func Begin(ctx context.Context) (func(), bool) {
	r := FromContext(ctx)
	if r == nil {
		return func() {}, true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.sealed {
		return func() {}, false
	}
	r.active++
	var once sync.Once
	return func() {
		once.Do(func() {
			r.mu.Lock()
			r.active--
			r.mu.Unlock()
			select {
			case r.changed <- struct{}{}:
			default:
			}
		})
	}, true
}

func OwnConnection(ctx context.Context, conn net.Conn) {
	if r := FromContext(ctx); r != nil {
		r.mu.Lock()
		if r.sealed {
			r.mu.Unlock()
			conn.Close()
			return
		}
		r.connections = append(r.connections, conn)
		r.mu.Unlock()
	}
}

// CloseTransport seals admission, closes owned sockets and joins tracked work.
// It deliberately does not claim ownership of uninstrumented core goroutines.
func (r *Recorder) CloseTransport(ctx context.Context) bool {
	r.mu.Lock()
	r.sealed = true
	connections := r.connections
	r.connections = nil
	r.mu.Unlock()
	for _, conn := range connections {
		conn.Close()
	}
	for {
		r.mu.Lock()
		active := r.active
		r.mu.Unlock()
		if active == 0 {
			return true
		}
		select {
		case <-r.changed:
		case <-ctx.Done():
			return false
		}
	}
}
