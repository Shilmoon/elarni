package tuic

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"

	quic "github.com/sagernet/sing-quic/tuic"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	ST "github.com/sagernet/sing/common/tls"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
)

type serverTLS struct{ tlsAdapter }

func (c *serverTLS) Start() error                          { return nil }
func (c *serverTLS) Close() error                          { return nil }
func (c *serverTLS) Server(conn net.Conn) (ST.Conn, error) { return tls.Server(conn, c.config), nil }

// endless starts a download that never ends on every TCP request.
type endless struct{}

func (endless) NewConnectionEx(_ context.Context, conn net.Conn, _, _ M.Socksaddr, _ N.CloseHandlerFunc) {
	defer conn.Close()
	if _, err := conn.Read(make([]byte, 1)); err != nil {
		return
	}
	chunk := make([]byte, 64<<10)
	for {
		if _, err := conn.Write(chunk); err != nil {
			return
		}
	}
}

func (endless) NewPacketConnectionEx(_ context.Context, conn N.PacketConn, _, _ M.Socksaddr, _ N.CloseHandlerFunc) {
	conn.Close()
}

// Every TCP flow is a stream of one QUIC connection. Downloads the app stopped reading held the whole
// connection window with their unread bytes (8 at quic-go's first 2 MiB stream window fill 16 MiB),
// so every other flow froze. Past twice the window of unread bytes it still freezes, to bound memory.
func TestStalledDownloadsLeaveTheConnectionUsable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
	certPEM, keyPEM := certificate.ToPEM()
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	service, err := quic.NewService[int](quic.ServiceOptions{Context: ctx, Logger: logger.NOP(), Handler: endless{},
		TLSConfig: &serverTLS{tlsAdapter{config: &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"h3"}}, timeout: 10 * time.Second}}})
	if err != nil {
		t.Fatal(err)
	}
	id := [16]byte{1}
	service.UpdateUsers([]int{1}, [][16]byte{id}, []string{"p"})
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Start(socket); err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	client, err := quic.NewClient(quic.ClientOptions{Context: ctx, Dialer: N.SystemDialer, ServerAddress: M.SocksaddrFromNet(socket.LocalAddr()),
		TLSConfig:   &tlsAdapter{config: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}, MinVersion: tls.VersionTLS13}, timeout: 10 * time.Second},
		QUICOptions: clientQUICOptions, UUID: id, Password: "p"})
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseWithError(nil)
	origin := M.ParseSocksaddr("127.0.0.1:80")
	for range 12 {
		stalled, err := client.DialConn(ctx, origin)
		if err != nil {
			t.Fatal(err)
		}
		defer stalled.Close()
		stalled.Write([]byte{1})
	}
	time.Sleep(time.Second) // the server fills what the stalled streams may hold
	fresh, err := client.DialConn(ctx, origin)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	fresh.Write([]byte{1})
	fresh.SetReadDeadline(time.Now().Add(5 * time.Second))
	if n, err := io.ReadFull(fresh, make([]byte, 1<<20)); err != nil {
		t.Fatalf("a fresh download got %d bytes: %v", n, err)
	}
}
