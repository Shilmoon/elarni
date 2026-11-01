package splithttp_test

import (
	"context"
	"io"
	gonet "net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"github.com/xtls/xray-core/transport/internet/stat"
)

// h1Session dials a packet-up session over plain HTTP/1.1 to addr.
func h1Session(t *testing.T, addr string) stat.Connection {
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x","mode":"packet-up"}`),
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	conn, err := splithttp.Dial(context.Background(), destination(t, addr), client)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// countingXHTTP listens for XHTTP over plain HTTP and counts the bytes its sessions receive.
func countingXHTTP(t *testing.T) (string, *atomic.Int64, chan error) {
	var received atomic.Int64
	failed := make(chan error, 1)
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, freePort(t), &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
	}, func(conn stat.Connection) {
		go func() {
			defer conn.Close()
			b := make([]byte, 64<<10)
			for {
				n, err := conn.Read(b)
				received.Add(int64(n))
				if err != nil {
					select {
					case failed <- err:
					default:
					}
					return
				}
			}
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String(), &received, failed
}

// front is a reverse proxy to an XHTTP server, as nginx or a CDN would be.
func front(t *testing.T, backend string, configure func(*httptest.Server)) *httptest.Server {
	target := &url.URL{Scheme: "http", Host: backend}
	proxy := &httputil.ReverseProxy{Rewrite: func(r *httputil.ProxyRequest) { r.SetURL(target) }, FlushInterval: -1}
	server := httptest.NewUnstartedServer(proxy)
	if configure != nil {
		configure(server)
	}
	server.Start()
	t.Cleanup(server.Close)
	return server
}

func waitReceived(t *testing.T, received *atomic.Int64, sent int64) {
	for deadline := time.Now().Add(5 * time.Second); received.Load() < sent; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("received %d of %d bytes", received.Load(), sent)
		}
	}
}

// A POST waiting for a slow connection setup must not let later POSTs overtake
// it by more than the server's reorder window: HTTP/2 and HTTP/3 sessions wait
// until each post is written, and HTTP/1.1 waited only until it was serialized.
func TestH1PacketUpKeepsPostsInOrderOverSlowSetup(t *testing.T) {
	backend, received, failed := countingXHTTP(t)
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			client, err := ln.Accept()
			if err != nil {
				return
			}
			server, err := gonet.Dial("tcp", backend)
			if err != nil {
				client.Close()
				continue
			}
			// Each new connection's first bytes wait out a slow TCP and TLS setup.
			go delayCopy(server, client, 0, time.Now().Add(time.Second))
			go delayCopy(client, server, 0, time.Time{})
		}
	}()
	conn := h1Session(t, ln.Addr().String())
	var sent int64
	b := make([]byte, 160)
	for start := time.Now(); time.Since(start) < 5*time.Second; time.Sleep(20 * time.Millisecond) {
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write failed after %d bytes: %v", sent, err)
		}
		sent += int64(len(b))
		select {
		case err := <-failed:
			t.Fatalf("the server ended the session after %d of %d bytes: %v", received.Load(), sent, err)
		default:
		}
	}
	waitReceived(t, received, sent)
}

// A rejected post loses its data, so the session must fail as it does over HTTP/2.
func TestH1PacketUpFailsOnRejectedPost(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		io.Copy(io.Discard, r.Body)
		if seq, _ := strconv.Atoi(r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]); seq >= 5 {
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	t.Cleanup(server.Close)
	conn := h1Session(t, server.Listener.Addr().String())
	b := make([]byte, 100)
	for start := time.Now(); time.Since(start) < 2*time.Second; time.Sleep(20 * time.Millisecond) {
		if _, err := conn.Write(b); err != nil {
			return
		}
	}
	t.Fatal("the server rejected posts and every write still succeeded")
}

// A reader waiting for the reply to a rejected post must not wait for the idle timeout.
func TestH1PacketUpRejectedPostFailsReads(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)
	conn := h1Session(t, server.Listener.Addr().String())
	if _, err := conn.Write(make([]byte, 100)); err != nil {
		t.Fatal(err)
	}
	read := make(chan error, 1)
	go func() { _, err := conn.Read(make([]byte, 1)); read <- err }()
	select {
	case err := <-read:
		if err == nil {
			t.Fatal("the post was rejected and a read succeeded")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the post was rejected and reads still block")
	}
}

// nginx closes a keep-alive connection after keepalive_requests (1000 by default)
// with "Connection: close" and does not process the posts pipelined after it.
func TestH1PacketUpSurvivesKeepAliveClose(t *testing.T) {
	backend, received, _ := countingXHTTP(t)
	type requests struct{}
	server := front(t, backend, func(s *httptest.Server) {
		proxy := s.Config.Handler
		s.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Context().Value(requests{}).(*atomic.Int32).Add(1)%5 == 0 {
				w.Header().Set("Connection", "close")
			}
			proxy.ServeHTTP(w, r)
		})
		s.Config.ConnContext = func(ctx context.Context, c gonet.Conn) context.Context {
			return context.WithValue(ctx, requests{}, new(atomic.Int32))
		}
		s.Listener = lingeringListener{s.Listener}
	})
	// The round trip keeps several posts in flight behind the closing response.
	relay, _ := delayRelay(t, server.Listener.Addr().String(), 50*time.Millisecond)
	conn := h1Session(t, relay)
	var sent int64
	b := make([]byte, 100)
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(5 * time.Millisecond) {
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write failed after %d bytes: %v", sent, err)
		}
		sent += int64(len(b))
	}
	waitReceived(t, received, sent)
}

// A front server closes keep-alive connections that stay idle (nginx after
// keepalive_timeout, 75 s by default). A post must not go to such a connection.
func TestH1PacketUpSurvivesIdleClose(t *testing.T) {
	backend, received, _ := countingXHTTP(t)
	server := front(t, backend, func(s *httptest.Server) { s.Config.IdleTimeout = 100 * time.Millisecond })
	conn := h1Session(t, server.Listener.Addr().String())
	var sent int64
	b := make([]byte, 100)
	for range 5 {
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write failed after %d bytes: %v", sent, err)
		}
		sent += int64(len(b))
		time.Sleep(300 * time.Millisecond)
	}
	waitReceived(t, received, sent)
}

// A front may send interim answers, such as 103 Early Hints, before each final one;
// taking them as answers shifts every later answer onto the wrong post.
func TestH1PacketUpSkipsInterimResponses(t *testing.T) {
	backend, received, _ := countingXHTTP(t)
	server := front(t, backend, func(s *httptest.Server) {
		proxy := s.Config.Handler
		s.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodPost {
				w.Header().Set("Link", "</hint>; rel=preload")
				w.WriteHeader(http.StatusEarlyHints)
				w.Header().Del("Link")
			}
			proxy.ServeHTTP(w, r)
		})
	})
	conn := h1Session(t, server.Listener.Addr().String())
	var sent int64
	b := make([]byte, 100)
	for range 20 {
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write failed after %d bytes: %v", sent, err)
		}
		sent += int64(len(b))
		time.Sleep(20 * time.Millisecond)
	}
	waitReceived(t, received, sent)
}

// lingeringListener closes connections as nginx does: it stops sending and
// discards what still arrives for a while, so no reset destroys the last response.
type lingeringListener struct{ gonet.Listener }

func (l lingeringListener) Accept() (gonet.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return lingeringConn{c.(*gonet.TCPConn)}, nil
}

type lingeringConn struct{ *gonet.TCPConn }

func (c lingeringConn) Close() error {
	c.CloseWrite()
	c.SetReadDeadline(time.Now().Add(time.Second))
	io.Copy(io.Discard, c.TCPConn)
	return c.TCPConn.Close()
}
