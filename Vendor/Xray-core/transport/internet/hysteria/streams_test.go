package hysteria

import (
	"context"
	gotls "crypto/tls"
	"net"
	"testing"
	"time"

	"github.com/apernet/quic-go"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
)

// A connection beyond the server's stream limit failed at once instead of waiting
// for the credit of a closed stream (360 of 1500 sequential connections failed).
func TestStreamsBeyondTheServerLimitWaitForCredit(t *testing.T) {
	certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
	certPEM, keyPEM := certificate.ToPEM()
	pair, err := gotls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := quic.ListenAddr("127.0.0.1:0", &gotls.Config{Certificates: []gotls.Certificate{pair}, NextProtos: []string{"t"}}, &quic.Config{MaxIncomingStreams: 1})
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
			go func() {
				buffer := make([]byte, 1)
				stream.Read(buffer) // the client's byte ends the stream
				stream.CancelRead(0)
				stream.Close()
			}()
		}
	}()
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tr := &quic.Transport{Conn: socket}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := tr.Dial(ctx, listener.Addr(), &gotls.Config{InsecureSkipVerify: true, NextProtos: []string{"t"}}, &quic.Config{})
	if err != nil {
		t.Fatal(err)
	}
	c := &client{lock: make(chan struct{}, 1), current: &connection{Conn: conn, tr: tr, pktConn: socket}}
	defer c.clean(true)

	first, err := c.tcp(ctx)
	if err != nil {
		t.Fatal(err)
	}
	opened := make(chan error, 1)
	go func() {
		_, err := c.tcp(ctx)
		opened <- err
	}()
	time.Sleep(100 * time.Millisecond)
	first.Write([]byte{1})
	first.Close()
	if err := <-opened; err != nil {
		t.Fatalf("second stream: %v", err)
	}
}
