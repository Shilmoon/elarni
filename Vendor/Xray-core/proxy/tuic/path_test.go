package tuic

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"

	quic "github.com/sagernet/sing-quic/tuic"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/transport/internet"
	xTLS "github.com/xtls/xray-core/transport/internet/tls"
)

func TestMain(m *testing.M) {
	probeBound = 500 * time.Millisecond // set before any watcher reads it
	os.Exit(m.Run())
}

var userID = [16]byte{1}

// startService runs a TUIC server on loopback whose flows handler serves.
func startService(tb testing.TB, handler quic.ServiceHandler) net.Addr {
	certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
	certPEM, keyPEM := certificate.ToPEM()
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		tb.Fatal(err)
	}
	service, err := quic.NewService[int](quic.ServiceOptions{Context: context.Background(), Logger: logger.NOP(), Handler: handler,
		TLSConfig: &serverTLS{tlsAdapter{config: &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"h3"}}, timeout: 10 * time.Second}}})
	if err != nil {
		tb.Fatal(err)
	}
	service.UpdateUsers([]int{1}, [][16]byte{userID}, []string{"p"})
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		tb.Fatal(err)
	}
	if err := service.Start(socket); err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { service.Close() })
	return socket.LocalAddr()
}

func BenchmarkDownloadThroughTheSocketDialer(b *testing.B) {
	ctx := context.Background()
	sockets := &socketDialer{sockets: make(map[*ownedSocket]struct{})}
	defer sockets.Close()
	client, err := quic.NewClient(quic.ClientOptions{Context: ctx, Dialer: sockets, ServerAddress: M.SocksaddrFromNet(startService(b, endless{})),
		TLSConfig:   &tlsAdapter{config: &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}, MinVersion: tls.VersionTLS13}, timeout: 10 * time.Second},
		QUICOptions: clientQUICOptions, UUID: userID, Password: "p"})
	if err != nil {
		b.Fatal(err)
	}
	defer client.CloseWithError(nil)
	conn, err := client.DialConn(ctx, M.ParseSocksaddr("127.0.0.1:80"))
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte{1})
	chunk := make([]byte, 64<<10)
	b.SetBytes(int64(len(chunk)))
	for b.Loop() {
		if _, err := io.ReadFull(conn, chunk); err != nil {
			b.Fatal(err)
		}
	}
}

// echo echoes every TCP flow.
type echo struct{}

func (echo) NewConnectionEx(_ context.Context, conn net.Conn, _, _ M.Socksaddr, _ N.CloseHandlerFunc) {
	io.Copy(conn, conn)
	conn.Close()
}

func (echo) NewPacketConnectionEx(_ context.Context, conn N.PacketConn, _, _ M.Socksaddr, _ N.CloseHandlerFunc) {
	conn.Close()
}

// relay stands in for the network between a client and a server until it is cut.
type relay struct {
	net.PacketConn
	cut atomic.Bool
}

func newRelay(t *testing.T, server net.Addr) *relay {
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { socket.Close() })
	r := &relay{PacketConn: socket}
	go func() {
		var client net.Addr
		packet := make([]byte, 65535)
		for {
			n, from, err := socket.ReadFrom(packet)
			if err != nil {
				return
			}
			to := server
			if from.String() == server.String() {
				to = client
			} else {
				client = from
			}
			if !r.cut.Load() && to != nil {
				socket.WriteTo(packet[:n], to)
			}
		}
	}()
	return r
}

type noGateway struct{ internet.Dialer }

func (noGateway) SetOutboundGateway(context.Context, *session.Outbound) {}

// tuicClient is the outbound with its server behind r.
func tuicClient(t *testing.T, r *relay) *Client {
	at := r.LocalAddr().(*net.UDPAddr)
	c := &Client{config: &ClientConfig{Address: xnet.NewIPOrDomain(xnet.IPAddress(at.IP)), Port: uint32(at.Port), Uuid: userID[:], Password: "p", Heartbeat: int64(10 * time.Second)},
		stream: &internet.MemoryStreamConfig{SecuritySettings: &xTLS.Config{ServerName: "localhost", AllowInsecure: true}}}
	t.Cleanup(func() { c.Close() })
	return c
}

// dialFlow opens a TCP flow as Process does, and returns the upstream that took it.
func dialFlow(t *testing.T, c *Client) (net.Conn, *upstream) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := c.initialize(ctx, noGateway{})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := client.DialConn(ctx, M.ParseSocksaddr("127.0.0.1:80"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	c.mu.Lock()
	defer c.mu.Unlock()
	return conn, c.current
}

func echoes(conn net.Conn) error {
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte{1}); err != nil {
		return err
	}
	_, err := io.ReadFull(conn, make([]byte, 1))
	return err
}

// signalMove sends the socket path signal and waits until new flows no longer get c's connection.
func signalMove(t *testing.T, c *Client) {
	internet.SocketPathChanged()
	for deadline := time.Now().Add(2 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		c.mu.Lock()
		current := c.current
		c.mu.Unlock()
		if current == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the connection stayed in use for new flows after the socket path changed")
		}
	}
}

func closesWithin(u *upstream, within time.Duration) bool {
	for deadline := time.Now().Add(within); len(u.sockets.open()) > 0; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			return false
		}
	}
	return true
}

// Platforms report path changes that leave the old network working; a connection that still
// answers must keep the flows on it.
func TestSpuriousPathChangeKeepsAHealthyConnectionsFlows(t *testing.T) {
	c := tuicClient(t, newRelay(t, startService(t, echo{})))
	flow, old := dialFlow(t, c)
	if err := echoes(flow); err != nil {
		t.Fatal(err)
	}
	signalMove(t, c)
	time.Sleep(3 * probeBound) // the check has run
	if len(old.sockets.open()) == 0 {
		t.Fatal("a connection that answered was closed")
	}
	if err := echoes(flow); err != nil {
		t.Fatalf("a flow on a healthy connection broke after a path change: %v", err)
	}
	fresh, current := dialFlow(t, c)
	if current == old {
		t.Fatal("a new flow got the connection from before the path change")
	}
	if err := echoes(fresh); err != nil {
		t.Fatal(err)
	}
	flow.Close()
	if !closesWithin(old, time.Second) {
		t.Error("a retired connection stayed open after its last flow ended")
	}
}

// After a real change the old path delivers nothing; its flows stalled until the idle timeout.
func TestPathChangeClosesAConnectionThatStoppedAnswering(t *testing.T) {
	r := newRelay(t, startService(t, echo{}))
	c := tuicClient(t, r)
	flow, old := dialFlow(t, c)
	if err := echoes(flow); err != nil {
		t.Fatal(err)
	}
	r.cut.Store(true)
	signalMove(t, c)
	if !closesWithin(old, probeBound+time.Second) {
		t.Fatal("a connection on a dead path stayed open")
	}
	if err := echoes(flow); err == nil {
		t.Fatal("a flow on a closed connection still echoed")
	}
}

// The change is often reported while the old path still delivers what was in flight, or a
// moment before it dies. What arrives then is no answer: counted as one, it kept the dead
// connection and its flows until the idle timeout.
func TestPathChangeIgnoresWhatTheOldPathStillDelivers(t *testing.T) {
	r := newRelay(t, startService(t, endless{}))
	c := tuicClient(t, r)
	flow, old := dialFlow(t, c)
	if _, err := flow.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	go io.Copy(io.Discard, flow)
	signalMove(t, c)
	time.Sleep(30 * time.Millisecond)
	r.cut.Store(true)
	if !closesWithin(old, probeBound+time.Second) {
		t.Fatal("a connection on a dead path stayed open")
	}
}

// The outbound's Close ends the connections it retired, and its watch.
func TestCloseEndsRetiredConnections(t *testing.T) {
	c := tuicClient(t, newRelay(t, startService(t, echo{})))
	flow, old := dialFlow(t, c)
	if err := echoes(flow); err != nil {
		t.Fatal(err)
	}
	signalMove(t, c)
	c.Close()
	if len(old.sockets.open()) > 0 {
		t.Error("a retired connection outlived its outbound")
	}
}

// Platforms report a network change as a burst of signals; each must not cost another dial.
func TestBurstOfPathChangesRetiresOnceMore(t *testing.T) {
	moves, done := make(chan struct{}, 1), make(chan struct{})
	var passes atomic.Int32
	defer close(done)
	go coalesce(moves, done, func() { passes.Add(1) })
	for range 10 { // spread over one check, as a path monitor reports a change
		select {
		case moves <- struct{}{}:
		default:
		}
		time.Sleep(probeBound / 10)
	}
	time.Sleep(3 * probeBound)
	if n := passes.Load(); n < 1 || n > 2 {
		t.Fatalf("a burst of 10 signals ran %d passes, want 1 or 2", n)
	}
}
