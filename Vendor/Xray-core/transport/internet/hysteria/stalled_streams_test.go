package hysteria

import (
	"context"
	gotls "crypto/tls"
	"io"
	"net"
	"testing"
	"time"

	"github.com/apernet/quic-go"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
	"github.com/xtls/xray-core/transport/internet"
)

// Every TCP flow is a stream of one QUIC connection. Three downloads the app stopped reading
// held the whole connection window with their unread bytes, so every other flow froze.
func TestStalledDownloadsLeaveTheConnectionUsable(t *testing.T) {
	for _, c := range []struct {
		name   string
		params *internet.QuicParams
	}{
		{"chrome parrot", &internet.QuicParams{}},
		{"no parrot", &internet.QuicParams{DisableChromeParrot: true}},
	} {
		t.Run(c.name, func(t *testing.T) {
			certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
			certPEM, keyPEM := certificate.ToPEM()
			pair, err := gotls.X509KeyPair(certPEM, keyPEM)
			if err != nil {
				t.Fatal(err)
			}
			listener, err := quic.ListenAddr("127.0.0.1:0", &gotls.Config{Certificates: []gotls.Certificate{pair}, NextProtos: []string{"t"}}, &quic.Config{})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			go func() {
				conn, err := listener.Accept(context.Background())
				if err != nil {
					return
				}
				for {
					stream, err := conn.AcceptStream(context.Background())
					if err != nil {
						return
					}
					go func() { // the client's byte starts an endless download
						if _, err := stream.Read(make([]byte, 1)); err != nil {
							return
						}
						chunk := make([]byte, 64<<10)
						for {
							if _, err := stream.Write(chunk); err != nil {
								return
							}
						}
					}()
				}
			}()
			socket, err := net.ListenPacket("udp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			tr := &quic.Transport{Conn: socket}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			conn, err := tr.Dial(ctx, listener.Addr(), &gotls.Config{InsecureSkipVerify: true, NextProtos: []string{"t"}}, newQuicConfig(c.params))
			if err != nil {
				t.Fatal(err)
			}
			client := &client{lock: make(chan struct{}, 1), conn: conn, tr: tr, pktConn: socket}
			defer client.close()

			for range 3 {
				stalled, err := client.tcp(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer stalled.Close()
				stalled.Write([]byte{1})
			}
			time.Sleep(time.Second) // the server fills what the stalled streams may hold
			fresh, err := client.tcp(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer fresh.Close()
			fresh.Write([]byte{1})
			fresh.SetReadDeadline(time.Now().Add(5 * time.Second))
			if n, err := io.ReadFull(fresh, make([]byte, 1<<20)); err != nil {
				t.Fatalf("a fresh download got %d bytes: %v", n, err)
			}
		})
	}
}
