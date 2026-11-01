package splithttp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/probe"
)

// Bound establishment, not the lifetime of a streaming proxy connection.
var setupTimeout = 16 * time.Second

// errStalled ends a request that outlived its own setup or response bound. Unlike
// its caller giving up, that means the connection under it is not delivering.
var errStalled = fmt.Errorf("xhttp transport stalled: %w", context.DeadlineExceeded)

type requestLifetime struct {
	mu                          sync.Mutex
	ctx                         context.Context
	cancel                      context.CancelCauseFunc
	setup, response             *time.Timer
	stopParent                  func() bool
	acquired, responded, closed bool
}

func newRequestLifetime(parent context.Context) *requestLifetime {
	ctx, cancel := context.WithCancelCause(probe.RequestContext(parent))
	r := &requestLifetime{ctx: ctx, cancel: cancel}
	r.setup = time.AfterFunc(setupTimeout, func() { r.failSetup(errStalled) })
	r.stopParent = context.AfterFunc(parent, func() { r.failSetup(parent.Err()) })
	return r
}

func (r *requestLifetime) failSetup(err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.acquired && !r.closed {
		probe.Emit(r.ctx, "xhttp_setup_failed", err, 0)
		r.cancel(err)
	}
}

func (r *requestLifetime) acquire(parent context.Context) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if parent.Err() != nil {
		r.cancel(parent.Err())
	}
	if r.ctx.Err() != nil || r.closed {
		return false
	}
	r.acquired = true
	r.setup.Stop()
	r.stopParent()
	return true
}

func (r *requestLifetime) awaitResponse() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.responded || r.closed || r.response != nil {
		return
	}
	r.response = time.AfterFunc(setupTimeout, func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if !r.responded && !r.closed {
			probe.Emit(r.ctx, "xhttp_response_timeout", errStalled, 0)
			r.cancel(errStalled)
		}
	})
}

func (r *requestLifetime) responseReceived() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.responded = true
	if r.response != nil {
		r.response.Stop()
	}
}

// connectionFailed reports whether the request ended through its connection, by a
// transport error or its own bound, rather than by its caller giving up.
func (r *requestLifetime) connectionFailed() bool {
	cause := context.Cause(r.ctx)
	return cause == nil || errors.Is(cause, errStalled)
}

func (r *requestLifetime) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	r.setup.Stop()
	r.stopParent()
	if r.response != nil {
		r.response.Stop()
	}
	r.cancel(context.Canceled)
}

// A stream-one peer may need the first payload before it sends response headers.
// Do not impose a data-idle deadline on a socket the application has not used yet.
type requestBody struct {
	io.Reader
	lifetime   *requestLifetime
	uploadOnly bool
}

func (b requestBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	if n > 0 && !b.uploadOnly {
		b.lifetime.awaitResponse()
	}
	return n, err
}

func (b requestBody) Close() error {
	if c, ok := b.Reader.(io.Closer); ok {
		return c.Close()
	}
	return nil
}
