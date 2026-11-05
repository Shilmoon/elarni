package httpupgrade_test

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/httpupgrade"
	"github.com/xtls/xray-core/transport/internet/tls"
)

const testHandshakeTimeout = 300 * time.Millisecond

func upgradeServer(t *testing.T, answer func(net.Conn)) (xnet.Destination, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	released := make(chan struct{})
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		answer(conn)
		_, _ = io.Copy(io.Discard, conn)
		close(released)
	}()
	return xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(listener.Addr().(*net.TCPAddr).Port)), released
}

func upgradeSettings(security any) *internet.MemoryStreamConfig {
	return &internet.MemoryStreamConfig{ProtocolName: "httpupgrade", ProtocolSettings: &httpupgrade.Config{}, SecuritySettings: security}
}

func readRequest(conn net.Conn) *bufio.Reader {
	reader := bufio.NewReader(conn)
	_, _ = http.ReadRequest(reader)
	return reader
}

// Neither the TLS handshake nor the upgrade reply had a deadline, and a failed upgrade
// kept its socket open.
func TestHTTPUpgradeHandshakeIsBoundedAndFailuresReleaseTheSocket(t *testing.T) {
	previous := tls.HandshakeTimeout
	tls.HandshakeTimeout = testHandshakeTimeout
	t.Cleanup(func() { tls.HandshakeTimeout = previous })
	for _, test := range []struct {
		name     string
		security any
		answer   func(net.Conn)
		timeout  bool
	}{
		{"utls silent", &tls.Config{ServerName: "fixture.invalid", Fingerprint: "chrome"}, func(net.Conn) {}, true},
		{"go tls silent", &tls.Config{ServerName: "fixture.invalid", Fingerprint: "unsafe"}, func(net.Conn) {}, true},
		{"no reply", nil, func(conn net.Conn) { readRequest(conn) }, true},
		{"refused upgrade", nil, func(conn net.Conn) {
			readRequest(conn)
			_, _ = conn.Write([]byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
		}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			dest, released := upgradeServer(t, test.answer)
			dialed := make(chan error, 1)
			go func() {
				conn, err := httpupgrade.Dial(context.Background(), dest, upgradeSettings(test.security))
				if conn != nil {
					conn.Close()
				}
				dialed <- err
			}()
			select {
			case err := <-dialed:
				if err == nil {
					t.Fatal("the upgrade failed, yet Dial returned a connection")
				}
				// The outbound retry loop gives up on a timeout instead of waiting it out again.
				if test.timeout && !errors.Is(err, context.DeadlineExceeded) {
					t.Fatalf("err %v, want context.DeadlineExceeded", err)
				}
			case <-time.After(testHandshakeTimeout + 3*time.Second):
				t.Fatal("Dial outlived the handshake budget")
			}
			select {
			case <-released:
			case <-time.After(2 * time.Second):
				t.Fatal("the failed dial kept its socket open")
			}
		})
	}
}

// The budget covers the upgrade only: an upgraded connection outlives it.
func TestHTTPUpgradeConnectionOutlivesTheHandshakeBudget(t *testing.T) {
	previous := tls.HandshakeTimeout
	tls.HandshakeTimeout = testHandshakeTimeout
	t.Cleanup(func() { tls.HandshakeTimeout = previous })
	dest, _ := upgradeServer(t, func(conn net.Conn) {
		reader := readRequest(conn)
		_, _ = conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"))
		_, _ = io.Copy(conn, reader)
	})
	conn, err := httpupgrade.Dial(context.Background(), dest, upgradeSettings(nil))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	time.Sleep(2 * testHandshakeTimeout)
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reply := make([]byte, 4)
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "ping" {
		t.Fatalf("echo %q, %v after the handshake budget", reply, err)
	}
}
