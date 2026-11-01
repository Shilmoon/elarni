package splithttp_test

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
)

// Far below the 16s production budget so timer paths run in seconds; still above the 1s dial deadline.
const testSetupTimeout = 2 * time.Second

func xhttpFixtureConfig(t *testing.T, value map[string]any) *internet.MemoryStreamConfig {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var config conf.StreamConfig
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	built, err := config.Build()
	if err != nil {
		t.Fatal(err)
	}
	settings, err := internet.ToMemoryStreamConfig(built)
	if err != nil {
		t.Fatal(err)
	}
	return settings
}
func xhttpFixtureDest(listener net.Listener) xnet.Destination {
	return xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), xnet.Port(listener.Addr().(*net.TCPAddr).Port))
}

// Regression: silent TLS/REALITY peers previously outlived the caller deadline,
// then returned a nil dial error after the peer was finally closed.
func TestXHTTPSilentHandshakeReturnsErrorAndReleasesSocket(t *testing.T) {
	t.Cleanup(splithttp.SetSetupTimeout(testSetupTimeout))
	for _, security := range []string{"tls", "reality", "default_budget"} {
		t.Run(security, func(t *testing.T) {
			t.Parallel()
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			accepted, released := make(chan struct{}), make(chan struct{})
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				close(accepted)
				_, _ = io.Copy(io.Discard, conn)
				close(released)
			}()
			actualSecurity := security
			if actualSecurity == "default_budget" {
				actualSecurity = "tls"
			}
			value := map[string]any{"network": "xhttp", "security": actualSecurity, "xhttpSettings": map[string]any{"mode": "auto", "xmux": map[string]any{"maxConnections": 1}}}
			if actualSecurity == "tls" {
				value["tlsSettings"] = map[string]any{"serverName": "fixture.invalid", "fingerprint": "chrome"}
			} else {
				key, err := ecdh.X25519().GenerateKey(rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				value["realitySettings"] = map[string]any{"serverName": "fixture.invalid", "fingerprint": "chrome", "publicKey": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()), "shortId": "0123456789abcdef"}
			}
			ctx := context.Background()
			if security != "default_budget" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 250*time.Millisecond)
				defer cancel()
			}
			started := time.Now()
			conn, err := splithttp.Dial(ctx, xhttpFixtureDest(listener), xhttpFixtureConfig(t, value))
			if conn != nil {
				conn.Close()
				t.Fatal("failed setup returned a connection")
			}
			if err == nil {
				t.Fatal("failed setup suppressed its error")
			}
			if security != "default_budget" && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("lost caller deadline: %v", err)
			}
			limit := 2 * time.Second
			if security == "default_budget" {
				limit = testSetupTimeout + 4*time.Second
				if time.Since(started) < testSetupTimeout*7/8 {
					t.Fatal("fixture did not exercise the setup timer")
				}
			}
			if time.Since(started) > limit {
				t.Fatal("setup exceeded its deadline")
			}
			select {
			case <-accepted:
			default:
				t.Fatal("fixture peer was not reached")
			}
			select {
			case <-released:
			case <-time.After(2 * time.Second):
				t.Fatal("canceled handshake leaked its TCP socket")
			}
		})
	}
}

// Regression: HTTP/2 shares one in-flight connection attempt per XMUX client, so a
// handshake that never completes held every flow assigned to that client until the
// flow that started it gave up (Android: 4.5-20 s stalls right after reconnecting).
func TestXHTTPStalledSetupDoesNotBlockOtherFlows(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	relay, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	stalled, released := make(chan struct{}), make(chan struct{})
	go func() {
		for first := true; ; first = false {
			conn, err := relay.Accept()
			if err != nil {
				return
			}
			if first { // a socket whose handshake never gets an answer
				close(stalled)
				go func() { _, _ = io.Copy(io.Discard, conn); conn.Close(); close(released) }()
				continue
			}
			upstream, err := net.Dial("tcp", server.Listener.Addr().String())
			if err != nil {
				conn.Close()
				continue
			}
			go func() { _, _ = io.Copy(upstream, conn); upstream.Close() }()
			go func() { _, _ = io.Copy(conn, upstream); conn.Close() }()
		}
	}()
	digest := sha256.Sum256(server.Certificate().Raw)
	settings := xhttpFixtureConfig(t, map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"h2"}, "pinnedPeerCertSha256": hex.EncodeToString(digest[:])}, "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/fixture", "xmux": map[string]any{"maxConnections": 1}}})
	// End the first flow before returning: its client reads the setup timeout that later tests change.
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan struct{})
	defer func() { cancelFirst(); <-firstDone }()
	go func() {
		defer close(firstDone)
		if conn, err := splithttp.Dial(firstCtx, xhttpFixtureDest(relay), settings); err == nil {
			conn.Close()
		}
	}()
	select {
	case <-stalled:
	case <-time.After(5 * time.Second):
		t.Fatal("first flow did not dial")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	started := time.Now()
	conn, err := splithttp.Dial(ctx, xhttpFixtureDest(relay), settings)
	if err != nil {
		t.Fatalf("second flow waited behind the stalled handshake for %v: %v", time.Since(started), err)
	}
	conn.Close()
	if elapsed := time.Since(started); elapsed > 4*time.Second {
		t.Fatalf("second flow waited %v behind the stalled handshake", elapsed)
	}
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("abandoned handshake leaked its TCP socket")
	}
}

// Real H2 sockets distinguish setup bounds from a valid long-lived data stream.
func TestXHTTPResponseLifetime(t *testing.T) {
	t.Cleanup(splithttp.SetSetupTimeout(testSetupTimeout))
	for _, scenario := range []string{"healthy", "silent_headers", "status_error", "idle_before_payload", "stream_up_no_headers"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			streamUpBytes := make(chan byte, 16)
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if scenario == "stream_up_no_headers" {
					if r.Method == "GET" {
						w.WriteHeader(200)
						w.(http.Flusher).Flush()
						for {
							select {
							case b := <-streamUpBytes:
								if _, err := w.Write([]byte{b}); err != nil {
									return
								}
								w.(http.Flusher).Flush()
							case <-r.Context().Done():
								return
							}
						}
					}
					// Valid stream-up without padding need not flush response headers.
					for {
						b := make([]byte, 1)
						if _, err := io.ReadFull(r.Body, b); err != nil {
							return
						}
						select {
						case streamUpBytes <- b[0]:
						case <-r.Context().Done():
							return
						}
					}
				}
				if scenario == "status_error" {
					w.WriteHeader(503)
					w.(http.Flusher).Flush()
					<-r.Context().Done()
					return
				}
				if scenario == "silent_headers" {
					_, _ = io.Copy(io.Discard, r.Body)
					return
				}
				for {
					b := make([]byte, 1)
					if _, err := io.ReadFull(r.Body, b); err != nil {
						return
					}
					if _, err := w.Write(b); err != nil {
						return
					}
					w.(http.Flusher).Flush()
				}
			}))
			server.EnableHTTP2 = true
			server.StartTLS()
			defer server.Close()
			digest := sha256.Sum256(server.Certificate().Raw)
			mode := "stream-one"
			if scenario == "stream_up_no_headers" {
				mode = "stream-up"
			}
			settings := xhttpFixtureConfig(t, map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"h2"}, "pinnedPeerCertSha256": hex.EncodeToString(digest[:])}, "xhttpSettings": map[string]any{"mode": mode, "path": "/fixture"}})
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			conn, err := splithttp.Dial(ctx, xhttpFixtureDest(server.Listener), settings)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			exchange := func() {
				t.Helper()
				if _, err := conn.Write([]byte("x")); err != nil {
					t.Fatal(err)
				}
				b := make([]byte, 1)
				if _, err := io.ReadFull(conn, b); err != nil || string(b) != "x" {
					t.Fatalf("healthy stream failed: %q %v", b, err)
				}
			}
			switch scenario {
			case "healthy", "stream_up_no_headers":
				exchange()
				time.Sleep(testSetupTimeout + time.Second)
				exchange()
			case "idle_before_payload":
				time.Sleep(testSetupTimeout + time.Second)
				exchange()
			case "silent_headers":
				if _, err := conn.Write([]byte("x")); err != nil {
					t.Fatal(err)
				}
				started := time.Now()
				_, err := conn.Read(make([]byte, 1))
				if !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > testSetupTimeout+4*time.Second {
					t.Fatalf("missing response did not fail with its deadline: %v", err)
				}
			case "status_error":
				_, err := conn.Read(make([]byte, 1))
				if err == nil || !strings.Contains(err.Error(), "503") {
					t.Fatalf("HTTP error lost: %v", err)
				}
			}
		})
	}
}

// Regression: a stream its caller gave up on, during setup or before the
// response, marked the shared connection closed, so XMUX retired it and the
// next stream paid for a new TCP+TLS handshake.
func TestXHTTPCallerCancelKeepsSharedConnection(t *testing.T) {
	for _, scenario := range []string{"cancel_during_setup", "close_before_response"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			var accepted atomic.Int32
			// Stream-one echo: no response headers before the first payload byte.
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				for {
					b := make([]byte, 1)
					if _, err := io.ReadFull(r.Body, b); err != nil {
						return
					}
					if _, err := w.Write(b); err != nil {
						return
					}
					w.(http.Flusher).Flush()
				}
			}))
			server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
				if state == http.StateNew {
					accepted.Add(1)
				}
			}
			server.EnableHTTP2 = true
			server.StartTLS()
			defer server.Close()
			digest := sha256.Sum256(server.Certificate().Raw)
			settings := xhttpFixtureConfig(t, map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"h2"}, "pinnedPeerCertSha256": hex.EncodeToString(digest[:])}, "xhttpSettings": map[string]any{"mode": "stream-one", "path": "/fixture", "xmux": map[string]any{"maxConnections": 1}}})
			dest := xhttpFixtureDest(server.Listener)
			open := func(ctx context.Context) net.Conn {
				t.Helper()
				conn, err := splithttp.Dial(ctx, dest, settings)
				if err != nil {
					t.Fatal(err)
				}
				return conn
			}
			exchange := func(conn net.Conn) {
				t.Helper()
				if _, err := conn.Write([]byte("x")); err != nil {
					t.Fatal(err)
				}
				b := make([]byte, 1)
				if _, err := io.ReadFull(conn, b); err != nil || string(b) != "x" {
					t.Fatalf("stream failed: %q %v", b, err)
				}
			}
			first := open(context.Background())
			defer first.Close()
			exchange(first)
			established := accepted.Load() // a hedged first dial may have opened two

			// The probe lets the test join the request goroutine, which used to set the mark.
			ctx, recorder := probe.New(context.Background(), "")
			switch scenario {
			case "cancel_during_setup":
				ctx, cancel := context.WithCancel(ctx)
				defer cancel()
				// The caller gives up while the transport hands this request a connection.
				ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{GetConn: func(string) { cancel() }})
				if conn, err := splithttp.Dial(ctx, dest, settings); !errors.Is(err, context.Canceled) {
					if conn != nil {
						conn.Close()
					}
					t.Fatalf("canceled setup returned %v", err)
				}
			case "close_before_response":
				open(ctx).Close()
			}
			recorder.CloseTransport(context.Background())
			if splithttp.XmuxConnClosed(dest, settings) {
				t.Fatal("a stream its caller gave up on closed the shared connection")
			}
			second := open(context.Background())
			defer second.Close()
			exchange(second)
			if n := accepted.Load(); n != established {
				t.Fatalf("the next stream opened %d new TCP connections instead of reusing the shared one", n-established)
			}
		})
	}
}

// sync.Pool drops idle HTTP/1.1 upload sockets at GC. Each must close then, as
// upstream expects, not stay open until the dialer is released.
func TestXHTTPDroppedUploadConnectionsClose(t *testing.T) {
	var open, posts atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		io.Copy(io.Discard, r.Body)
		posts.Add(1)
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		switch state {
		case http.StateNew:
			open.Add(1)
		case http.StateClosed, http.StateHijacked:
			open.Add(-1)
		}
	}
	server.Start()
	defer server.Close()
	settings := xhttpFixtureConfig(t, map[string]any{"network": "xhttp", "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/fixture"}})
	defer internet.ReleaseTransport(settings)
	conn, err := splithttp.Dial(context.Background(), xhttpFixtureDest(server.Listener), settings)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for want := int32(1); want <= 6; want++ {
		if _, err := conn.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
		for deadline := time.Now().Add(3 * time.Second); posts.Load() < want; time.Sleep(5 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatal("upload not delivered")
			}
		}
		runtime.GC() // drops the pooled upload socket
	}
	// The download GET stays open, and at most one upload socket is still pooled.
	for deadline := time.Now().Add(5 * time.Second); open.Load() > 2; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("%d sockets still open after the pool dropped them", open.Load())
		}
		runtime.GC()
	}
}
