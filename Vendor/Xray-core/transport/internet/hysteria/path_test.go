package hysteria

import (
	"context"
	gotls "crypto/tls"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/apernet/quic-go"
	"github.com/apernet/quic-go/quicvarint"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

func TestMain(m *testing.M) {
	probeBound = 500 * time.Millisecond // set before any watcher reads it
	os.Exit(m.Run())
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

// echoServer echoes every TCP request stream after its frame type.
func echoServer(t *testing.T) *quic.Listener {
	certificate, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"))
	certPEM, keyPEM := certificate.ToPEM()
	pair, err := gotls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := quic.ListenAddr("127.0.0.1:0", &gotls.Config{Certificates: []gotls.Certificate{pair}, NextProtos: []string{"h3"}}, &quic.Config{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept(context.Background())
			if err != nil {
				return
			}
			go func() {
				for {
					stream, err := conn.AcceptStream(context.Background())
					if err != nil {
						return
					}
					go func() {
						if _, err := quicvarint.Read(quicvarint.NewReader(stream)); err == nil {
							io.Copy(stream, stream)
						}
						stream.Close()
					}()
				}
			}()
		}
	}()
	return listener
}

// pooledClient is a client in the pool whose connection reaches the server through r.
func pooledClient(t *testing.T, r *relay) *client {
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tr := &quic.Transport{Conn: socket}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := tr.Dial(ctx, r.LocalAddr(), &gotls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}}, newQuicConfig(&internet.QuicParams{DisableChromeParrot: true}))
	if err != nil {
		t.Fatal(err)
	}
	c := &client{lock: make(chan struct{}, 1), current: &connection{Conn: conn, tr: tr, pktConn: socket}}
	key := dialerConf{xnet.DestinationFromAddr(socket.LocalAddr()), &internet.MemoryStreamConfig{}}
	initmanager.Do(manager.start)
	manager.Lock()
	manager.m[key] = c
	manager.Unlock()
	t.Cleanup(func() {
		manager.Lock()
		delete(manager.m, key)
		manager.Unlock()
		c.clean(true)
	})
	return c
}

func (c *client) state() (current *connection, retired, moves int) {
	c.lock <- struct{}{}
	defer c.unlock()
	return c.current, len(c.retired), c.moves
}

func echoes(conn stat.Connection) error {
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte{1}); err != nil {
		return err
	}
	_, err := io.ReadFull(conn, make([]byte, 1))
	return err
}

// retired waits until the socket path signal moved c off its connection, and returns that connection.
func retired(t *testing.T, c *client) *connection {
	old, _, _ := c.state()
	internet.SocketPathChanged()
	for deadline := time.Now().Add(2 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if current, n, _ := c.state(); current == nil && n == 1 {
			return old
		}
		if time.Now().After(deadline) {
			t.Fatal("the connection stayed in use for new streams after the socket path changed")
		}
	}
}

// Platforms report path changes that leave the old network working; a connection that still
// answers must keep the streams on it.
func TestSpuriousPathChangeKeepsAHealthyConnectionsStreams(t *testing.T) {
	c := pooledClient(t, newRelay(t, echoServer(t).Addr()))
	stream, err := c.tcp(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := echoes(stream); err != nil {
		t.Fatal(err)
	}
	old := retired(t, c)
	time.Sleep(3 * probeBound) // the check has run
	if !old.active() {
		t.Fatal("a connection that answered was closed")
	}
	if err := echoes(stream); err != nil {
		t.Fatalf("a stream on a healthy connection broke after a path change: %v", err)
	}
	stream.Close()
	time.Sleep(3 * idleCleanupInterval / 2)
	if old.active() {
		t.Error("a retired connection stayed open after its last stream ended")
	}
}

// After a real change the old path delivers nothing; its streams stalled until the idle timeout.
func TestPathChangeClosesAConnectionThatStoppedAnswering(t *testing.T) {
	r := newRelay(t, echoServer(t).Addr())
	c := pooledClient(t, r)
	stream, err := c.tcp(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := echoes(stream); err != nil {
		t.Fatal(err)
	}
	r.cut.Store(true)
	old := retired(t, c)
	select {
	case <-old.Context().Done():
	case <-time.After(probeBound + time.Second):
		t.Fatal("a connection on a dead path stayed open")
	}
	if err := echoes(stream); err == nil {
		t.Fatal("a stream on a closed connection still echoed")
	}
}

// Platforms report a network change as a burst of signals; each must not cost another dial.
func TestBurstOfPathChangesRetiresOnceMore(t *testing.T) {
	c := pooledClient(t, newRelay(t, echoServer(t).Addr()))
	time.Sleep(probeBound) // a watcher pass from an earlier test is over
	_, _, before := c.state()
	for range 10 { // spread over one check, as a path monitor reports a change
		internet.SocketPathChanged()
		time.Sleep(probeBound / 10)
	}
	time.Sleep(3 * probeBound)
	if _, _, moves := c.state(); moves-before < 1 || moves-before > 2 {
		t.Fatalf("a burst of 10 signals retired connections %d times, want 1 or 2", moves-before)
	}
}

// Without pings a quiet half minute ended the connection and every stream on it.
func TestKeepAliveDefaultsToTenSeconds(t *testing.T) {
	if got := newQuicConfig(&internet.QuicParams{}).KeepAlivePeriod; got != 10*time.Second {
		t.Errorf("default keepalive %v", got)
	}
	if got := newQuicConfig(&internet.QuicParams{KeepAlivePeriod: 25}).KeepAlivePeriod; got != 25*time.Second {
		t.Errorf("configured keepalive 25 s became %v", got)
	}
}

// Every new flow waited behind one dial holding the lock, and when it failed, dialed again in
// turn; the first flow's cancellation aborted the dial the others waited for.
func TestConcurrentDialsShareOneBoundedDial(t *testing.T) {
	defer func(d time.Duration) { dialTimeout = d }(dialTimeout)
	dialTimeout = 300 * time.Millisecond
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	sources := make(chan string, 1000)
	go func() {
		packet := make([]byte, 2048)
		for {
			_, from, err := server.ReadFrom(packet)
			if err != nil {
				return
			}
			sources <- from.String()
		}
	}()
	streamSettings := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}, SecuritySettings: &tls.Config{}}
	defer internet.ReleaseTransport(streamSettings)
	dest := xnet.DestinationFromAddr(server.LocalAddr())
	first, cancelFirst := context.WithCancel(context.Background())
	results := make(chan time.Duration, 5)
	started := time.Now()
	for i := range 5 {
		ctx := context.Background()
		if i == 0 {
			ctx = first
		}
		go func() {
			if _, err := Dial(ctx, dest, streamSettings); err == nil {
				t.Error("dialed a server that never answers")
			}
			results <- time.Since(started)
		}()
		if i == 0 { // the first flow's dial is under way
			sources <- <-sources
		}
	}
	time.Sleep(50 * time.Millisecond)
	cancelFirst()
	for range 5 {
		if elapsed := <-results; elapsed > dialTimeout+time.Second {
			t.Errorf("a dial took %v, bound %v", elapsed, dialTimeout)
		}
	}
	if late := time.Since(started); late < dialTimeout {
		t.Errorf("the first flow's cancellation ended the shared dial after %v", late)
	}
	seen := map[string]bool{}
	for len(sources) > 0 {
		seen[<-sources] = true
	}
	if len(seen) != 1 {
		t.Errorf("5 concurrent flows dialed from %d sockets, want 1", len(seen))
	}
}
