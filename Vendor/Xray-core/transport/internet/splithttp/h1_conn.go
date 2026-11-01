package splithttp

import (
	"bufio"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
)

// errNotProcessed answers a request the server closed its connection without
// reading, so the request can go out again on another connection.
var errNotProcessed = errors.New("the server closed the connection before reading the request")

// H1Conn pipelines HTTP/1.1 posts: a request goes out while the responses to the
// ones before it are on their way, and a reader matches the responses up in order.
type H1Conn struct {
	net.Conn
	mu      sync.Mutex
	pending []h1Request // written and not yet answered, oldest first
	used    bool
	closed  bool // takes no more requests
}

type h1Request struct {
	answer chan error
	// The first request on a connection is not sent again: a server that closes
	// a new connection without an answer would close the next one too.
	first bool
}

func NewH1Conn(conn net.Conn) *H1Conn {
	c := &H1Conn{Conn: conn}
	go c.readResponses(bufio.NewReader(conn))
	return c
}

func (c *H1Conn) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// post writes a request and returns the channel its answer arrives on.
func (c *H1Conn) post(request []byte) (<-chan error, error) {
	r := h1Request{answer: make(chan error, 1)}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, errNotProcessed
	}
	r.first, c.used = !c.used, true
	c.pending = append(c.pending, r)
	c.Conn.SetReadDeadline(time.Time{})
	c.mu.Unlock()
	if _, err := c.Conn.Write(request); err != nil {
		// A request that did not go out whole was not read; the reader answers the others.
		c.mu.Lock()
		if n := len(c.pending); n > 0 && c.pending[n-1].answer == r.answer {
			c.pending = c.pending[:n-1]
		}
		c.closed = true
		c.mu.Unlock()
		if r.first {
			return nil, err
		}
		return nil, errNotProcessed
	}
	return r.answer, nil
}

// readResponses answers the pending requests in order. It closes the connection
// once that fails, the server closes it, or it stays idle for net.ConnIdleTimeout.
func (c *H1Conn) readResponses(responses *bufio.Reader) {
	for {
		c.mu.Lock()
		if len(c.pending) == 0 {
			if c.closed {
				c.mu.Unlock()
				c.Conn.Close()
				return
			}
			c.Conn.SetReadDeadline(time.Now().Add(net.ConnIdleTimeout))
		}
		c.mu.Unlock()
		if _, err := responses.Peek(1); err != nil {
			if e, ok := err.(net.Error); ok && e.Timeout() {
				c.mu.Lock()
				if len(c.pending) == 0 {
					c.closed = true // idle for net.ConnIdleTimeout; the loop closes it
				}
				c.mu.Unlock()
				continue
			}
			// A server closing cleanly before an answer read none of the pending requests.
			c.end(err, err == io.EOF)
			return
		}
		resp, err := http.ReadResponse(responses, nil)
		// Interim answers such as 103 Early Hints come before the final one and carry no body.
		for err == nil && resp.StatusCode >= 100 && resp.StatusCode < 200 && resp.StatusCode != http.StatusSwitchingProtocols {
			resp, err = http.ReadResponse(responses, nil)
		}
		if err == nil {
			_, err = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		c.mu.Lock()
		if err != nil || len(c.pending) == 0 {
			c.mu.Unlock()
			c.end(errors.New("bad upload response").Base(err), false)
			return
		}
		r := c.pending[0]
		c.pending = c.pending[1:]
		c.mu.Unlock()
		if resp.StatusCode != http.StatusOK {
			r.answer <- errors.New("bad status code:", resp.Status)
		} else {
			r.answer <- nil
		}
		if resp.Close {
			c.end(errNotProcessed, true) // the server reads no request after this one
			return
		}
	}
}

// end closes the connection and answers its pending requests. When unread, the
// server read none of them, and all but a first request can go out again.
func (c *H1Conn) end(err error, unread bool) {
	c.mu.Lock()
	pending := c.pending
	c.pending, c.closed = nil, true
	c.mu.Unlock()
	c.Conn.Close()
	for _, r := range pending {
		if unread && !r.first {
			r.answer <- errNotProcessed
		} else {
			r.answer <- err
		}
	}
}
