package splithttp_test

import (
	"context"
	"errors"
	"io"
	gonet "net"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

// xhttpServer serves XHTTP over HTTP/3 when h3 is set, else HTTP/2, with handle for every session.
func xhttpServer(t *testing.T, h3 bool, quicParams *internet.QuicParams, handle func(stat.Connection)) string {
	security := &tls.Config{Certificate: []*tls.Certificate{certificate()}}
	if h3 {
		security.NextProtocol = []string{"h3"}
	}
	port := freePort(t)
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, port, &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
		SecurityType:     "tls",
		SecuritySettings: security,
		QuicParams:       quicParams,
	}, func(conn stat.Connection) { go handle(conn) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return "127.0.0.1:" + port.String()
}

func echoServer(t *testing.T, h3 bool, quicParams *internet.QuicParams) string {
	return xhttpServer(t, h3, quicParams, func(conn stat.Connection) {
		defer conn.Close()
		io.Copy(conn, conn)
	})
}

func xhttpClient(t *testing.T, h3 bool, settings string) *internet.MemoryStreamConfig {
	security := &tls.Config{ServerName: "localhost", AllowInsecure: true}
	if h3 {
		security.NextProtocol = []string{"h3"}
	}
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, settings),
		SecurityType:     "tls",
		SecuritySettings: security,
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	return client
}

func dialXHTTP(t *testing.T, ctx context.Context, dest net.Destination, client *internet.MemoryStreamConfig) stat.Connection {
	t.Helper()
	conn, err := splithttp.Dial(ctx, dest, client)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// echo sends one byte and waits for it to come back.
func echo(conn gonet.Conn, b byte) error {
	result := make(chan error, 1)
	go func() {
		if _, err := conn.Write([]byte{b}); err != nil {
			result <- err
			return
		}
		got := make([]byte, 1)
		if _, err := io.ReadFull(conn, got); err != nil {
			result <- err
		} else if got[0] != b {
			result <- errors.New("echoed another byte")
		} else {
			result <- nil
		}
	}()
	select {
	case err := <-result:
		return err
	case <-time.After(5 * time.Second):
		return errors.New("no echo in 5 s")
	}
}

// tcpRelay forwards connections to target and counts them; while drop is set it
// swallows their bytes both ways without closing them, as a dead network path does.
func tcpRelay(t *testing.T, target string, drop *atomic.Bool) (string, *atomic.Int32) {
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var open []gonet.Conn
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range open {
			c.Close()
		}
	})
	var accepted atomic.Int32
	forward := func(dst, src gonet.Conn) {
		defer dst.Close()
		b := make([]byte, 32<<10)
		for {
			n, err := src.Read(b)
			if err != nil {
				return
			}
			if drop.Load() {
				continue
			}
			if _, err := dst.Write(b[:n]); err != nil {
				return
			}
		}
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			up, err := gonet.Dial("tcp", target)
			if err != nil {
				c.Close()
				continue
			}
			accepted.Add(1)
			mu.Lock()
			open = append(open, c, up)
			mu.Unlock()
			go forward(up, c)
			go forward(c, up)
		}
	}()
	return ln.Addr().String(), &accepted
}

// pathFixture is an echo server behind a relay that can go silent, and a stream-one client.
func pathFixture(t *testing.T, h3 bool) (dest net.Destination, client *internet.MemoryStreamConfig, drop *atomic.Bool, connections func() int) {
	drop = new(atomic.Bool)
	server := echoServer(t, h3, nil)
	var relay string
	if h3 {
		relay, connections = udpRelay(t, server, 0, drop)
	} else {
		var accepted *atomic.Int32
		relay, accepted = tcpRelay(t, server, drop)
		connections = func() int { return int(accepted.Load()) }
	}
	return destination(t, relay), xhttpClient(t, h3, `{"path":"/x","mode":"stream-one","xmux":{"maxConnections":1}}`), drop, connections
}

// A network change the embedder reports may not have moved this connection's path (Wi-Fi
// stays up when Ethernet takes the default route). A connection that answers keeps its
// streams, while new streams go to a connection dialed on the current path.
func TestPathChangeKeepsAnsweringConnections(t *testing.T) {
	for _, h3 := range []bool{false, true} {
		t.Run(map[bool]string{false: "h2", true: "h3"}[h3], func(t *testing.T) {
			t.Cleanup(splithttp.SetPathChangeTiming(500*time.Millisecond, 50*time.Millisecond))
			dest, client, _, connections := pathFixture(t, h3)
			old := dialXHTTP(t, context.Background(), dest, client)
			if err := echo(old, 1); err != nil {
				t.Fatal(err)
			}
			time.Sleep(200 * time.Millisecond) // quiet, so only the check can draw an answer
			internet.SocketPathChanged()
			time.Sleep(time.Second) // past the bound, by which a failed check closes the connection
			if err := echo(old, 2); err != nil {
				t.Fatalf("a stream on a connection that answers broke after a network change: %v", err)
			}
			if err := echo(dialXHTTP(t, context.Background(), dest, client), 3); err != nil {
				t.Fatal(err)
			}
			if n := connections(); n != 2 {
				t.Fatalf("%d connections after the change, want a new one for the new stream", n)
			}
		})
	}
}

// After a real path change the old connection's packets go nowhere. Its streams used to
// stall until the HTTP/2 ping (45 + 15 s) or the QUIC idle timeout (30 s) gave up. A
// connection kept through an earlier change that did not affect it is checked again.
func TestPathChangeClosesDeadConnections(t *testing.T) {
	for _, h3 := range []bool{false, true} {
		for _, earlier := range []bool{false, true} {
			t.Run(map[bool]string{false: "h2", true: "h3"}[h3]+map[bool]string{false: "", true: "_after_a_harmless_change"}[earlier], func(t *testing.T) {
				testPathChangeClosesDeadConnections(t, h3, earlier)
			})
		}
	}
}

func testPathChangeClosesDeadConnections(t *testing.T, h3, earlier bool) {
	t.Cleanup(splithttp.SetPathChangeTiming(500*time.Millisecond, 50*time.Millisecond))
	dest, client, drop, _ := pathFixture(t, h3)
	old := dialXHTTP(t, context.Background(), dest, client)
	if err := echo(old, 1); err != nil {
		t.Fatal(err)
	}
	if earlier {
		internet.SocketPathChanged()
		time.Sleep(time.Second)
		if err := echo(old, 2); err != nil {
			t.Fatal(err)
		}
	}
	drop.Store(true)
	internet.SocketPathChanged()
	read := make(chan error, 1)
	go func() {
		_, err := old.Read(make([]byte, 1))
		read <- err
	}()
	select {
	case err := <-read:
		if err == nil {
			t.Fatal("read from a dead path")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a stream on a dead path stayed open past the bound")
	}
}

// The change is often reported while the old path still delivers what was in flight, or a
// moment before it dies. What arrives then is no answer: counted as one, it kept the dead
// connection and its streams open until the idle timeout.
func TestPathChangeIgnoresWhatTheOldPathStillDelivers(t *testing.T) {
	for _, h3 := range []bool{false, true} {
		t.Run(map[bool]string{false: "h2", true: "h3"}[h3], func(t *testing.T) {
			t.Cleanup(splithttp.SetPathChangeTiming(500*time.Millisecond, 50*time.Millisecond))
			server := xhttpServer(t, h3, nil, func(conn stat.Connection) {
				defer conn.Close()
				if _, err := conn.Read(make([]byte, 1)); err != nil {
					return
				}
				for chunk := make([]byte, 1<<10); ; time.Sleep(5 * time.Millisecond) {
					if _, err := conn.Write(chunk); err != nil {
						return
					}
				}
			})
			drop := new(atomic.Bool)
			var relay string
			if h3 {
				relay, _ = udpRelay(t, server, 0, drop)
			} else {
				relay, _ = tcpRelay(t, server, drop)
			}
			client := xhttpClient(t, h3, `{"path":"/x","mode":"stream-one","xmux":{"maxConnections":1}}`)
			download := dialXHTTP(t, context.Background(), destination(t, relay), client)
			if _, err := download.Write([]byte{1}); err != nil {
				t.Fatal(err)
			}
			if _, err := io.ReadFull(download, make([]byte, 1<<10)); err != nil {
				t.Fatal(err)
			}
			failed := make(chan struct{})
			go func() {
				defer close(failed)
				for b := make([]byte, 32<<10); ; {
					if _, err := download.Read(b); err != nil {
						return
					}
				}
			}()
			internet.SocketPathChanged()
			time.Sleep(30 * time.Millisecond)
			drop.Store(true)
			select {
			case <-failed:
			case <-time.After(2 * time.Second):
				t.Fatal("a stream on a dead path stayed open past the bound")
			}
		})
	}
}

// udp is the destination XHTTP/3 keeps its connections under.
func udp(dest net.Destination) net.Destination {
	dest.Network = net.Network_UDP
	return dest
}

// On a slow link the answer to the check's PING queues behind the data in flight. A
// download that kept arriving must not be closed as dead after a harmless network change.
func TestPathChangeKeepsSlowBusyConnections(t *testing.T) {
	for _, h3 := range []bool{false, true} {
		t.Run(map[bool]string{false: "h2", true: "h3"}[h3], func(t *testing.T) {
			t.Cleanup(splithttp.SetPathChangeTiming(500*time.Millisecond, 50*time.Millisecond))
			const oneWay = 400 * time.Millisecond // the round trip outlasts the bound
			server := xhttpServer(t, h3, nil, func(conn stat.Connection) {
				defer conn.Close()
				if _, err := conn.Read(make([]byte, 1)); err != nil {
					return
				}
				for chunk := make([]byte, 1<<10); ; time.Sleep(10 * time.Millisecond) {
					if _, err := conn.Write(chunk); err != nil {
						return
					}
				}
			})
			var relay string
			if h3 {
				relay = udpDelayRelay(t, server, oneWay)
			} else {
				relay, _ = delayRelay(t, server, oneWay)
			}
			client := xhttpClient(t, h3, `{"path":"/x","mode":"stream-one","xmux":{"maxConnections":1}}`)
			download := dialXHTTP(t, context.Background(), destination(t, relay), client)
			if _, err := download.Write([]byte{1}); err != nil {
				t.Fatal(err)
			}
			var received atomic.Int64
			failed := make(chan error, 1)
			go func() {
				for b := make([]byte, 32<<10); ; {
					n, err := download.Read(b)
					received.Add(int64(n))
					if err != nil {
						failed <- err
						return
					}
				}
			}()
			for deadline := time.Now().Add(10 * time.Second); received.Load() == 0; time.Sleep(10 * time.Millisecond) {
				if time.Now().After(deadline) {
					t.Fatal("the download did not start")
				}
			}
			internet.SocketPathChanged()
			time.Sleep(1500 * time.Millisecond) // past the bound and past the PING's round trip
			before := received.Load()
			time.Sleep(300 * time.Millisecond)
			select {
			case err := <-failed:
				t.Fatalf("a download that kept arriving broke after a network change: %v", err)
			default:
			}
			if received.Load() == before {
				t.Fatal("the download stopped after a network change")
			}
		})
	}
}

func quicTransports() int {
	stacks := make([]byte, 1<<20)
	for {
		n := runtime.Stack(stacks, true)
		if n < len(stacks) {
			return strings.Count(string(stacks[:n]), "quic-go.(*Transport).listen(")
		}
		stacks = make([]byte, 2*len(stacks))
	}
}

// Where QUIC is blocked, every XHTTP/3 dial fails; each failure left its UDP socket and
// the QUIC transport reading it open until the process ended.
func TestXHTTP3FailedDialsReleaseTheirSockets(t *testing.T) {
	t.Cleanup(splithttp.SetSetupTimeout(300 * time.Millisecond))
	silent, err := gonet.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	client := xhttpClient(t, true, `{"path":"/x","mode":"stream-one"}`)
	dest := destination(t, silent.LocalAddr().String())
	before := quicTransports()
	for range 3 {
		if conn, err := splithttp.Dial(context.Background(), dest, client); err == nil {
			conn.Close()
			t.Fatal("a dial to a silent server succeeded")
		}
	}
	for deadline := time.Now().Add(3 * time.Second); quicTransports() > before; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("%d QUIC transports of failed dials still read their sockets", quicTransports()-before)
		}
	}
}

// quic-go servers, Xray's before this change and upstream's, allow 100 streams per
// connection. Session 101 on one connection waited for a stream until its response bound
// retired the connection, and no session there could post while all streams were taken.
func TestXHTTP3SessionsBeyondTheStreamLimitDoNotStall(t *testing.T) {
	t.Cleanup(splithttp.SetSetupTimeout(2 * time.Second))
	server := echoServer(t, true, &internet.QuicParams{MaxIncomingStreams: 100})
	client := xhttpClient(t, true, `{"path":"/x","mode":"packet-up","xmux":{"maxConnections":1}}`)
	dest := destination(t, server)
	const sessions = 110
	conns := make([]stat.Connection, sessions)
	for i := range conns {
		conns[i] = dialXHTTP(t, context.Background(), dest, client)
	}
	errs := make(chan error, sessions)
	for i, conn := range conns {
		go func() { errs <- echo(conn, byte(i)) }()
	}
	for range sessions {
		if err := <-errs; err != nil {
			t.Fatalf("a session failed with %d open: %v", sessions, err)
		}
	}
	if splithttp.XmuxConnClosed(udp(dest), client) {
		t.Fatal("a connection was retired as stalled")
	}
}

// Flows that start together wait for one HTTP/3 handshake. When the app of the flow that
// started it closed, the handshake ended and every waiting flow failed with it.
func TestXHTTP3CanceledFirstFlowKeepsTheSharedDial(t *testing.T) {
	relay := udpDelayRelay(t, echoServer(t, true, nil), 150*time.Millisecond)
	client := xhttpClient(t, true, `{"path":"/x","mode":"stream-one","xmux":{"maxConnections":1}}`)
	dest := destination(t, relay)
	first, cancelFirst := context.WithCancel(context.Background())
	go func() {
		if conn, err := splithttp.Dial(first, dest, client); err == nil {
			conn.Close()
		}
	}()
	time.Sleep(50 * time.Millisecond) // the first flow starts the dial; it takes at least 300 ms
	const waiters = 4
	errs := make(chan error, waiters)
	for i := range waiters {
		go func() {
			conn, err := splithttp.Dial(context.Background(), dest, client)
			if err == nil {
				defer conn.Close()
				err = echo(conn, byte(i))
			}
			errs <- err
		}()
	}
	time.Sleep(50 * time.Millisecond)
	cancelFirst()
	for range waiters {
		if err := <-errs; err != nil {
			t.Fatalf("a flow waiting for the canceled flow's dial failed: %v", err)
		}
	}
	if splithttp.XmuxConnClosed(udp(dest), client) {
		t.Fatal("the canceled flow retired the shared connection")
	}
}
