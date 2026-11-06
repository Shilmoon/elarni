package splithttp

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"sync"
	"sync/atomic"

	"github.com/apernet/quic-go/http3"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
)

// interface to abstract between use of browser dialer, vs net/http
type DialerClient interface {
	IsClosed() bool

	// ctx, url, sessionId, body, uploadOnly
	OpenStream(context.Context, string, string, io.Reader, bool) (io.ReadCloser, net.Addr, net.Addr, error)

	// ctx, url, sessionId, seqStr, body, contentLength
	PostPacket(context.Context, string, string, string, buf.MultiBuffer) error
}

// implements splithttp.DialerClient in terms of direct network connections
type DefaultDialerClient struct {
	transportConfig *Config
	client          *http.Client
	closed          atomic.Bool
	diagnosticID    uint64
	httpVersion     string
	// HTTP/1.1 upload connections, dialed with dialUploadConn
	uploadMu       sync.Mutex
	uploadConns    []*H1Conn
	uploadClosed   bool // set by Close: posts still writing must not pool their connections
	dialUploadConn func(ctxInner context.Context) (net.Conn, error)
	preconnect     *preconnect   // HTTP/2 only
	open           *atomic.Int32 // HTTP/2 and HTTP/3 connections up
}

func (c *DefaultDialerClient) IsClosed() bool {
	return c.closed.Load()
}

// warm reports whether a request would find a connection without a handshake.
func (c *DefaultDialerClient) warm() bool {
	return c.open.Load() > 0 || c.preconnect != nil && c.preconnect.waiting()
}

func (c *DefaultDialerClient) OpenStream(ctx context.Context, url string, sessionId string, body io.Reader, uploadOnly bool) (wrc io.ReadCloser, remoteAddr, localAddr net.Addr, err error) {
	if flightrecorder.Enabled() {
		ctx = flightrecorder.WithConnection(ctx, c.diagnosticID)
	}
	// this is done when the TCP/UDP connection to the server was established,
	// and we can unblock the Dial function and print correct net addresses in
	// logs
	lifetime := newRequestLifetime(ctx)
	type acquisition struct {
		remote, local net.Addr
		err           error
	}
	gotConn := make(chan acquisition, 1)
	var publish sync.Once
	send := func(a acquisition) { publish.Do(func() { gotConn <- a }) }
	parent := ctx
	ctx = httptrace.WithClientTrace(lifetime.ctx, &httptrace.ClientTrace{
		GotConn: func(connInfo httptrace.GotConnInfo) {
			probe.Record(ctx, probe.Event{Stage: "xhttp_connection_obtained", Reused: connInfo.Reused})
			if lifetime.acquire(parent) {
				if body == nil {
					lifetime.awaitResponse()
				}
				send(acquisition{remote: connInfo.Conn.RemoteAddr(), local: connInfo.Conn.LocalAddr()})
			}
		},
	})

	method := "GET" // stream-down
	if body != nil {
		method = c.transportConfig.GetNormalizedUplinkHTTPMethod() // stream-up/one
	}
	var requestReader io.Reader
	if body != nil {
		requestReader = requestBody{Reader: body, lifetime: lifetime, uploadOnly: uploadOnly}
	}
	req, err := http.NewRequestWithContext(ctx, method, url, requestReader)
	if err != nil {
		lifetime.close()
		errors.LogInfoInner(ctx, err, "failed to create HTTP request for "+url)
		return nil, nil, nil, err
	}
	c.transportConfig.FillStreamRequest(req, sessionId, "")
	finished, admitted := probe.Begin(ctx)
	if !admitted {
		lifetime.close()
		return nil, nil, nil, context.Canceled
	}

	responseReader := &WaitReadCloser{Wait: make(chan struct{}), cancel: lifetime.close}
	wrc = responseReader
	go func() {
		defer finished()
		resp, err := c.client.Do(req)
		lifetime.responseReceived()
		if err != nil {
			if cause := context.Cause(lifetime.ctx); cause != nil {
				err = cause
			}
		}
		stage := "xhttp_download_response"
		if body != nil {
			stage = "xhttp_upload_response"
		}
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		probe.Emit(ctx, stage, err, status)
		if err != nil {
			if !uploadOnly { // stream-down is enough
				if lifetime.connectionFailed() { // a caller giving up leaves the shared connection to other streams
					c.closed.Store(true)
				}
				errors.LogInfoInner(ctx, err, "failed to "+method+" "+url)
			}
			send(acquisition{err: err})
			common.Close(body)
			responseReader.CloseWithError(err)
			return
		}
		if resp.StatusCode != 200 && !uploadOnly {
			errors.LogInfo(ctx, "unexpected status ", resp.StatusCode)
		}
		if resp.StatusCode != 200 || uploadOnly { // stream-up
			if resp.StatusCode != 200 {
				resp.Body.Close()
				common.Close(body)
				responseReader.CloseWithError(fmt.Errorf("xhttp status %d", resp.StatusCode))
				return
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close() // if it is called immediately, the upload will be interrupted also
			common.Close(body)
			wrc.Close()
			return
		}
		responseReader.Set(resp.Body)
	}()

	select {
	case acquired := <-gotConn:
		if acquired.err != nil {
			responseReader.CloseWithError(acquired.err)
			return nil, nil, nil, acquired.err
		}
		return responseReader, acquired.remote, acquired.local, nil
	case <-lifetime.ctx.Done():
		err := context.Cause(lifetime.ctx)
		if lifetime.connectionFailed() {
			c.closed.Store(true)
		}
		common.Close(body)
		responseReader.CloseWithError(err)
		return nil, nil, nil, err
	}
}

func (c *DefaultDialerClient) PostPacket(ctx context.Context, url string, sessionId string, seqStr string, payload buf.MultiBuffer) error {
	if flightrecorder.Enabled() {
		ctx = flightrecorder.WithConnection(ctx, c.diagnosticID)
	}
	finished, admitted := probe.Begin(ctx)
	if !admitted {
		return context.Canceled
	}
	defer finished()
	method := c.transportConfig.GetNormalizedUplinkHTTPMethod()
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			probe.Record(ctx, probe.Event{Stage: "xhttp_connection_obtained", Reused: info.Reused})
		},
	})
	req, err := http.NewRequestWithContext(probe.RequestContext(ctx), method, url, nil)
	if err != nil {
		return err
	}
	c.transportConfig.FillPacketRequest(req, sessionId, seqStr, payload)

	if c.httpVersion != "1.1" {
		resp, err := c.client.Do(req)
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		probe.Emit(ctx, "xhttp_upload_response", err, status)
		if err != nil {
			c.closed.Store(true)
			return err
		}

		io.Copy(io.Discard, resp.Body)
		defer resp.Body.Close()

		if resp.StatusCode != 200 {
			return errors.New("bad status code:", resp.Status)
		}
	} else {
		// stringify the entire HTTP/1.1 request so it can be
		// safely retried. Without the caller's trace: the request
		// counts as written once it is on a connection.
		requestBuff := new(bytes.Buffer)
		requestBuff.Grow(512 + int(req.ContentLength))
		common.Must(req.WithContext(context.Background()).Write(requestBuff))

		requestCtx := probe.RequestContext(ctx)
		for {
			conn, err := c.uploadConn(requestCtx)
			if err != nil {
				return err
			}
			answer, err := conn.post(requestBuff.Bytes())
			if err == errNotProcessed {
				continue
			}
			if err != nil {
				return err
			}
			c.putUploadConn(conn) // the next post can follow on this connection at once
			if trace := httptrace.ContextClientTrace(ctx); trace != nil && trace.WroteRequest != nil {
				trace.WroteRequest(httptrace.WroteRequestInfo{})
			}
			select {
			case err = <-answer:
			case <-requestCtx.Done():
				return requestCtx.Err()
			}
			if err != errNotProcessed {
				return err
			}
		}
	}

	return nil
}

// uploadConn returns a pooled HTTP/1.1 upload connection or dials a new one.
func (c *DefaultDialerClient) uploadConn(ctx context.Context) (*H1Conn, error) {
	c.uploadMu.Lock()
	if c.uploadClosed {
		c.uploadMu.Unlock()
		return nil, errors.New("the XHTTP client is closed")
	}
	for len(c.uploadConns) > 0 {
		conn := c.uploadConns[len(c.uploadConns)-1]
		c.uploadConns = c.uploadConns[:len(c.uploadConns)-1]
		if !conn.isClosed() {
			c.uploadMu.Unlock()
			return conn, nil
		}
	}
	c.uploadMu.Unlock()
	conn, err := c.dialUploadConn(ctx)
	if err != nil {
		return nil, err
	}
	return NewH1Conn(conn), nil
}

func (c *DefaultDialerClient) putUploadConn(conn *H1Conn) {
	c.uploadMu.Lock()
	defer c.uploadMu.Unlock()
	if c.uploadClosed {
		conn.Close()
		return
	}
	c.uploadConns = append(c.uploadConns, conn)
}

// HTTP/1.1 downloads and HTTP/2 close themselves; HTTP/3 and the HTTP/1.1
// upload connections are closed here
func (c *DefaultDialerClient) Close() error {
	transport := c.client.Transport
	if h3Transport, ok := transport.(*http3.Transport); ok {
		h3Transport.Close()
	}
	c.uploadMu.Lock()
	for _, conn := range c.uploadConns {
		conn.Close()
	}
	c.uploadConns, c.uploadClosed = nil, true
	c.uploadMu.Unlock()
	return nil
}

type WaitReadCloser struct {
	Wait chan struct{}
	io.ReadCloser
	mu     sync.Mutex
	closed bool
	err    error
	cancel func()
}

func (w *WaitReadCloser) Set(rc io.ReadCloser) {
	if rc == nil {
		_ = w.Close()
		return
	}
	w.mu.Lock()
	if w.closed || w.ReadCloser != nil {
		w.mu.Unlock()
		_ = rc.Close()
		return
	}
	w.ReadCloser = rc
	close(w.Wait)
	w.mu.Unlock()
}

func (w *WaitReadCloser) Read(b []byte) (int, error) {
	<-w.Wait
	w.mu.Lock()
	rc, closed, err := w.ReadCloser, w.closed, w.err
	w.mu.Unlock()
	if closed || rc == nil {
		if err != nil {
			return 0, err
		}
		return 0, io.ErrClosedPipe
	}
	return rc.Read(b)
}

func (w *WaitReadCloser) Close() error {
	return w.CloseWithError(io.ErrClosedPipe)
}

func (w *WaitReadCloser) CloseWithError(err error) error {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return nil
	}
	w.closed = true
	w.err = err
	rc := w.ReadCloser
	if rc == nil {
		close(w.Wait)
	}
	w.mu.Unlock()
	if w.cancel != nil {
		w.cancel()
	}
	if rc != nil {
		return rc.Close()
	}
	return nil
}
