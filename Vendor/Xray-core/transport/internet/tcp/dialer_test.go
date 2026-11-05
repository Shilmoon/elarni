package tcp_test

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	gotls "crypto/tls"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/reality"
	"github.com/xtls/xray-core/transport/internet/tcp"
	"github.com/xtls/xray-core/transport/internet/tls"
)

const testHandshakeTimeout = 300 * time.Millisecond

func shortenHandshakeTimeout(t *testing.T) {
	previous := tls.HandshakeTimeout
	tls.HandshakeTimeout = testHandshakeTimeout
	t.Cleanup(func() { tls.HandshakeTimeout = previous })
}

// handshakeServer accepts one connection, lets answer act on it, then reports when the
// client releases its socket.
func handshakeServer(t *testing.T, answer func(net.Conn)) (xnet.Destination, <-chan struct{}) {
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

func silent(net.Conn) {}

// garbage answers the ClientHello with bytes no TLS client accepts, and keeps its side open.
func garbage(conn net.Conn) {
	_, _ = conn.Read(make([]byte, 4096))
	_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
}

func realitySettings(publicKey []byte) *reality.Config {
	return &reality.Config{ServerName: "fixture.invalid", Fingerprint: "chrome", PublicKey: publicKey, ShortId: make([]byte, 8), SpiderX: "/", SpiderY: make([]int64, 10)}
}

func rawSettings(security any) *internet.MemoryStreamConfig {
	return &internet.MemoryStreamConfig{ProtocolName: "tcp", ProtocolSettings: &tcp.Config{}, SecuritySettings: security}
}

// DPI that swallows the handshake used to hang a RAW dial until the kernel gave up, and a
// handshake that failed kept its socket open.
func TestRawHandshakeIsBoundedAndFailuresReleaseTheSocket(t *testing.T) {
	shortenHandshakeTimeout(t)
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	utlsSettings := &tls.Config{ServerName: "fixture.invalid", Fingerprint: "chrome"}
	goTLSSettings := &tls.Config{ServerName: "fixture.invalid", Fingerprint: "unsafe"}
	for _, test := range []struct {
		name     string
		security any
		answer   func(net.Conn)
		timeout  bool
	}{
		{"utls silent", utlsSettings, silent, true},
		{"utls garbage", utlsSettings, garbage, false},
		{"go tls silent", goTLSSettings, silent, true},
		{"go tls garbage", goTLSSettings, garbage, false},
		{"reality silent", realitySettings(key.PublicKey().Bytes()), silent, true},
		{"reality garbage", realitySettings(key.PublicKey().Bytes()), garbage, false},
		// A low-order key fails before the ClientHello is sent.
		{"reality bad key", realitySettings(make([]byte, 32)), silent, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			dest, released := handshakeServer(t, test.answer)
			dialed := make(chan error, 1)
			go func() {
				conn, err := tcp.Dial(context.Background(), dest, rawSettings(test.security))
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

// The budget covers the handshake only: an established connection outlives it.
func TestRawTLSConnectionOutlivesTheHandshakeBudget(t *testing.T) {
	shortenHandshakeTimeout(t)
	certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
	certPEM, keyPEM := certificate.ToPEM()
	pair, err := gotls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	for _, fingerprint := range []string{"chrome", "unsafe"} {
		dest, _ := handshakeServer(t, func(conn net.Conn) {
			server := gotls.Server(conn, &gotls.Config{Certificates: []gotls.Certificate{pair}})
			_, _ = io.Copy(server, server)
		})
		conn, err := tcp.Dial(context.Background(), dest, rawSettings(&tls.Config{ServerName: "localhost", AllowInsecure: true, Fingerprint: fingerprint}))
		if err != nil {
			t.Fatalf("%s: %v", fingerprint, err)
		}
		time.Sleep(2 * testHandshakeTimeout)
		reply := make([]byte, 4)
		_, err = conn.Write([]byte("ping"))
		if err == nil {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			_, err = io.ReadFull(conn, reply)
		}
		conn.Close()
		if err != nil || string(reply) != "ping" {
			t.Fatalf("%s: echo %q, %v after the handshake budget", fingerprint, reply, err)
		}
	}
}
