package websocket

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/tls"
)

// WSS with a uTLS fingerprint used to ignore gorilla's handshake timeout, and a failed
// handshake kept its socket open.
func TestWSSHandshakeIsBoundedAndFailuresReleaseTheSocket(t *testing.T) {
	previous := handshakeTimeout
	handshakeTimeout = 300 * time.Millisecond
	t.Cleanup(func() { handshakeTimeout = previous })
	for _, test := range []struct {
		name   string
		answer func(net.Conn)
	}{
		{"silent", func(net.Conn) {}},
		{"garbage", func(conn net.Conn) {
			_, _ = conn.Read(make([]byte, 4096))
			_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			released := make(chan struct{})
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				test.answer(conn)
				_, _ = io.Copy(io.Discard, conn)
				close(released)
			}()
			dest := xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(listener.Addr().(*net.TCPAddr).Port))
			settings := &internet.MemoryStreamConfig{ProtocolName: "websocket", ProtocolSettings: &Config{}, SecuritySettings: &tls.Config{ServerName: "fixture.invalid", Fingerprint: "chrome"}}
			dialed := make(chan error, 1)
			go func() {
				conn, err := Dial(context.Background(), dest, settings)
				if conn != nil {
					conn.Close()
				}
				dialed <- err
			}()
			select {
			case err := <-dialed:
				if err == nil {
					t.Fatal("the handshake failed, yet Dial returned a connection")
				}
			case <-time.After(handshakeTimeout + 3*time.Second):
				t.Fatal("Dial outlived gorilla's handshake timeout")
			}
			select {
			case <-released:
			case <-time.After(2 * time.Second):
				t.Fatal("the failed dial kept its socket open")
			}
		})
	}
}
