//go:build linux

package splithttp_test

import (
	"context"
	"net"
	"syscall"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
)

// silentPort is a loopback port whose accept queue is full: Linux drops further
// SYNs, so a dial to it stays in TCP connect until its context ends.
func silentPort(t *testing.T) xnet.Destination {
	t.Helper()
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Close(fd) })
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Listen(fd, 0); err != nil {
		t.Fatal(err)
	}
	name, err := syscall.Getsockname(fd)
	if err != nil {
		t.Fatal(err)
	}
	port := name.(*syscall.SockaddrInet4).Port
	address := net.JoinHostPort("127.0.0.1", xnet.Port(port).String())
	// A backlog of 0 queues one connection; the next SYN is dropped.
	for range 4 {
		conn, err := net.DialTimeout("tcp", address, 200*time.Millisecond)
		if err != nil {
			return xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), xnet.Port(port))
		}
		t.Cleanup(func() { conn.Close() })
	}
	t.Skip("this kernel accepted every connection; no port that drops SYNs")
	return xnet.Destination{}
}

// A probe that ends while its XHTTP connection is still in TCP connect must not
// wait for that dial: net/http detaches HTTP/1.1 dials from the request's
// cancellation, so it used to run to the setup timeout (16 s) and hold the
// probe's cleanup, which then reported instance_close_end timeout.
func TestXHTTPProbeCloseEndsAnInFlightDial(t *testing.T) {
	t.Cleanup(splithttp.SetSetupTimeout(30 * time.Second))
	for _, scenario := range []struct {
		name     string
		settings map[string]any
	}{
		{"http1", map[string]any{"network": "xhttp", "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/probe"}}},
		{"tls_http1", map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"http/1.1"}}, "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/probe"}}},
		{"tls_h2", map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"h2"}}, "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/probe"}}},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			dest := silentPort(t)
			settings := xhttpFixtureConfig(t, scenario.settings)
			base, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx, recorder := probe.New(base, "")
			dialed := make(chan error, 1)
			go func() {
				conn, err := splithttp.Dial(ctx, dest, settings)
				if err == nil {
					// packet-up returns before its first request dials.
					_, err = conn.Write([]byte("x"))
					conn.Close()
				}
				dialed <- err
			}()
			deadline := time.Now().Add(5 * time.Second)
			for !started(recorder) {
				if time.Now().After(deadline) {
					t.Fatal("the XHTTP dial never started")
				}
				time.Sleep(5 * time.Millisecond)
			}
			// As probe.go's cleanup does: cancel, close the instance, join.
			cancel()
			internet.ReleaseTransport(settings)
			join, stop := context.WithTimeout(context.Background(), 2*time.Second)
			defer stop()
			if !recorder.CloseTransport(join) {
				t.Fatal("probe cleanup waited on an XHTTP dial still in TCP connect")
			}
			select {
			case <-dialed:
			case <-time.After(5 * time.Second):
				t.Fatal("the caller's dial did not return after the probe closed")
			}
		})
	}
}

func started(recorder *probe.Recorder) bool {
	_, events := recorder.Snapshot()
	for _, event := range events {
		if event.Stage == "proxy_socket_start" {
			return true
		}
	}
	return false
}
