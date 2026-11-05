package grpc

import (
	"context"
	"io"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/grpc/encoding"
	"github.com/xtls/xray-core/transport/internet/stat"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
)

func TestMain(m *testing.M) {
	probeBound = 500 * time.Millisecond // set before any watcher reads it
	os.Exit(m.Run())
}

// relay stands in for the network between the client and the server; frozen, it delivers nothing.
type relay struct {
	net.Listener
	frozen atomic.Bool
}

func newRelay(t *testing.T, server string) *relay {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	r := &relay{Listener: listener}
	go func() {
		for {
			client, err := listener.Accept()
			if err != nil {
				return
			}
			upstream, err := net.Dial("tcp", server)
			if err != nil {
				client.Close()
				continue
			}
			go r.pipe(client, upstream)
			go r.pipe(upstream, client)
		}
	}()
	return r
}

func (r *relay) pipe(to, from net.Conn) {
	defer to.Close()
	data := make([]byte, 32<<10)
	for {
		n, err := from.Read(data)
		if err != nil {
			return
		}
		if !r.frozen.Load() {
			to.Write(data[:n])
		}
	}
}

// echoServer is an Xray gRPC server whose flows echo.
func echoServer(t *testing.T) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := grpc.NewServer()
	encoding.RegisterGRPCServiceServerX(s, Listener{ctx: context.Background(), handler: func(conn stat.Connection) {
		go func() {
			io.Copy(conn, conn)
			conn.Close()
		}()
	}}, "svc", "Tun", "TunMulti")
	go s.Serve(listener)
	t.Cleanup(s.Stop)
	return listener.Addr().String()
}

type flow struct {
	stat.Connection
	pooled *client
}

func dialFlow(t *testing.T, r *relay, streamSettings *internet.MemoryStreamConfig) flow {
	dest := net.DestinationFromAddr(r.Addr())
	conn, err := Dial(context.Background(), dest, streamSettings)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()
	return flow{conn, globalDialerMap[dialerConf{dest, streamSettings}]}
}

func echoes(conn stat.Connection) error {
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte{1}); err != nil {
		return err
	}
	_, err := io.ReadFull(conn, make([]byte, 1))
	return err
}

func pooled(streamSettings *internet.MemoryStreamConfig) bool {
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()
	for key := range globalDialerMap {
		if key.MemoryStreamConfig == streamSettings {
			return true
		}
	}
	return false
}

// signalMove sends the socket path signal and waits until new flows no longer get streamSettings' connection.
func signalMove(t *testing.T, streamSettings *internet.MemoryStreamConfig) {
	internet.SocketPathChanged()
	for deadline := time.Now().Add(2 * time.Second); pooled(streamSettings); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the connection stayed in use for new flows after the socket path changed")
		}
	}
}

func waitFor(c *client, state connectivity.State, within time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), within)
	defer cancel()
	for c.GetState() != state {
		if !c.WaitForStateChange(ctx, c.GetState()) {
			return false
		}
	}
	return true
}

// Platforms report path changes that leave the old network working; a connection that still
// answers must keep the flows on it.
func TestSpuriousPathChangeKeepsAHealthyConnectionsFlows(t *testing.T) {
	r := newRelay(t, echoServer(t))
	streamSettings := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{ServiceName: "svc"}}
	defer internet.ReleaseTransport(streamSettings)
	old := dialFlow(t, r, streamSettings)
	if err := echoes(old); err != nil {
		t.Fatal(err)
	}
	signalMove(t, streamSettings)
	time.Sleep(3 * probeBound) // the check has run
	if old.pooled.GetState() != connectivity.Ready {
		t.Fatalf("a connection that answered is %v", old.pooled.GetState())
	}
	if err := echoes(old); err != nil {
		t.Fatalf("a flow on a healthy connection broke after a path change: %v", err)
	}
	fresh := dialFlow(t, r, streamSettings)
	if fresh.pooled == old.pooled {
		t.Fatal("a new flow got the connection from before the path change")
	}
	if err := echoes(fresh); err != nil {
		t.Fatal(err)
	}
	old.Close()
	if !waitFor(old.pooled, connectivity.Shutdown, time.Second) {
		t.Errorf("a retired connection is %v after its last flow ended", old.pooled.GetState())
	}
}

// After a real change the old path delivers nothing; gRPC flows stalled for minutes.
func TestPathChangeClosesAConnectionThatStoppedAnswering(t *testing.T) {
	r := newRelay(t, echoServer(t))
	streamSettings := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{ServiceName: "svc"}}
	defer internet.ReleaseTransport(streamSettings)
	old := dialFlow(t, r, streamSettings)
	if err := echoes(old); err != nil {
		t.Fatal(err)
	}
	r.frozen.Store(true)
	time.Sleep(probeBound) // a watcher pass from an earlier test is over
	signalMove(t, streamSettings)
	if !waitFor(old.pooled, connectivity.Shutdown, probeBound+time.Second) {
		t.Fatalf("a connection on a dead path is %v", old.pooled.GetState())
	}
	if err := echoes(old); err == nil {
		t.Fatal("a flow on a closed connection still echoed")
	}
}

// Platforms report a network change as a burst of signals; each must not cost another dial.
func TestBurstOfPathChangesRetiresOnceMore(t *testing.T) {
	moves := make(chan struct{}, 1)
	var passes atomic.Int32
	defer close(moves)
	go coalesce(moves, func() { passes.Add(1) })
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
