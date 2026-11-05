package splithttp_test

import (
	"context"
	"encoding/binary"
	"io"
	gonet "net"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"slices"
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

// A packet-up session whose connection reaches its XMUX request limit moves its
// uploads to another connection. Its packets must not wait while that connection
// does its TCP and TLS handshakes (Discord streams lagged every 15-25 s).
func TestPacketUpRotationDoesNotStallUploads(t *testing.T) {
	const oneWay = 50 * time.Millisecond
	var mu sync.Mutex
	var delays []time.Duration
	server := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{Certificate: []*tls.Certificate{certificate()}},
	}
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, freePort(t), server, func(conn stat.Connection) {
		go func() {
			defer conn.Close()
			b := make([]byte, 8)
			for {
				if _, err := io.ReadFull(conn, b); err != nil {
					return
				}
				delay := time.Since(time.Unix(0, int64(binary.BigEndian.Uint64(b))))
				mu.Lock()
				delays = append(delays, delay)
				mu.Unlock()
			}
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	relay, connections := delayRelay(t, ln.Addr().String(), oneWay)

	// About 33 POSTs a second (scMinPostsIntervalMs 30), so a new connection every 0.6 s.
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x","mode":"packet-up","xmux":{"maxConnections":3,"hMaxRequestTimes":20}}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true},
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	conn, err := splithttp.Dial(context.Background(), destination(t, relay), client)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	sent := 0
	b := make([]byte, 8)
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(10 * time.Millisecond) {
		binary.BigEndian.PutUint64(b, uint64(time.Now().UnixNano()))
		if _, err := conn.Write(b); err != nil {
			t.Fatal(err)
		}
		sent++
	}
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		mu.Lock()
		received := len(delays)
		mu.Unlock()
		if received == sent {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("received %d of %d packets", received, sent)
		}
	}

	slices.Sort(delays)
	median, worst := delays[len(delays)/2], delays[len(delays)-1]
	t.Logf("%d connections, %d packets, delay median %v, worst %v", connections.Load(), sent, median, worst)
	if connections.Load() < 3 {
		t.Fatalf("the session used %d connections, want at least 3", connections.Load())
	}
	if worst-median > 2*oneWay {
		t.Fatalf("a connection change held packets %v longer than the median; the RTT is %v", worst-median, 2*oneWay)
	}
}

// delayRelay forwards connections to target and delays both directions by oneWay.
// The client's first bytes also wait out the round trip of the TCP handshake,
// which the relay itself answers at once.
func delayRelay(t *testing.T, target string, oneWay time.Duration) (string, *atomic.Int32) {
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var accepted atomic.Int32
	go func() {
		for {
			client, err := ln.Accept()
			if err != nil {
				return
			}
			accepted.Add(1)
			server, err := gonet.Dial("tcp", target)
			if err != nil {
				client.Close()
				continue
			}
			go delayCopy(server, client, oneWay, time.Now().Add(2*oneWay))
			go delayCopy(client, server, oneWay, time.Time{})
		}
	}()
	return ln.Addr().String(), &accepted
}

// delayCopy copies src to dst, sending each chunk delay after it arrived or after notBefore.
func delayCopy(dst, src gonet.Conn, delay time.Duration, notBefore time.Time) {
	type chunk struct {
		at   time.Time
		data []byte
	}
	chunks := make(chan chunk, 1024)
	go func() {
		defer dst.Close()
		for c := range chunks {
			time.Sleep(time.Until(c.at))
			if _, err := dst.Write(c.data); err != nil {
				src.Close()
				for range chunks {
				}
				return
			}
		}
	}()
	for {
		b := make([]byte, 32<<10)
		n, err := src.Read(b)
		if n > 0 {
			at := time.Now()
			if at.Before(notBefore) {
				at = notBefore
			}
			chunks <- chunk{at.Add(delay), b[:n]}
		}
		if err != nil {
			close(chunks)
			return
		}
	}
}

// Over HTTP/3, retiring a connection closes its QUIC transport. Rotation retired
// connections that still carried a session's posts, so the posts failed and the
// session ended.
func TestPacketUpH3RotationKeepsPostsInFlight(t *testing.T) {
	var received atomic.Int64
	port := freeUDPPort(t)
	server := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{Certificate: []*tls.Certificate{certificate()}, NextProtocol: []string{"h3"}},
	}
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, port, server, func(conn stat.Connection) {
		go func() {
			defer conn.Close()
			b := make([]byte, 8)
			for {
				if _, err := io.ReadFull(conn, b); err != nil {
					return
				}
				received.Add(1)
			}
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	relay := udpDelayRelay(t, "127.0.0.1:"+port.String(), 40*time.Millisecond)
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x","mode":"packet-up","xmux":{"maxConnections":3,"hMaxRequestTimes":10}}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true, NextProtocol: []string{"h3"}},
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	conn, err := splithttp.Dial(context.Background(), destination(t, relay), client)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sent := 0
	b := make([]byte, 8)
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(10 * time.Millisecond) {
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write %d failed: %v", sent, err)
		}
		sent++
	}
	for deadline := time.Now().Add(5 * time.Second); received.Load() < int64(sent); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("received %d of %d packets", received.Load(), sent)
		}
	}
}

func freeUDPPort(t *testing.T) net.Port {
	pc, err := gonet.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	return net.Port(pc.LocalAddr().(*gonet.UDPAddr).Port)
}

// udpDelayRelay forwards datagrams to target and delays both directions by oneWay.
func udpDelayRelay(t *testing.T, target string, oneWay time.Duration) string {
	addr, _ := udpRelay(t, target, oneWay, nil)
	return addr
}

// udpRelay is udpDelayRelay that counts the client sockets it saw and, while drop
// is set, swallows datagrams both ways, as a dead network path does.
func udpRelay(t *testing.T, target string, oneWay time.Duration, drop *atomic.Bool) (string, func() int) {
	pc, err := gonet.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	server, err := gonet.ResolveUDPAddr("udp", target)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	upstreams := map[string]*gonet.UDPConn{}
	t.Cleanup(func() {
		mu.Lock()
		defer mu.Unlock()
		for _, up := range upstreams {
			up.Close()
		}
	})
	dropping := func() bool { return drop != nil && drop.Load() }
	go func() {
		b := make([]byte, 65536)
		for {
			n, from, err := pc.ReadFrom(b)
			if err != nil {
				return
			}
			if dropping() {
				continue
			}
			mu.Lock()
			up, ok := upstreams[from.String()]
			if !ok {
				if up, err = gonet.DialUDP("udp", nil, server); err != nil {
					mu.Unlock()
					continue
				}
				upstreams[from.String()] = up
				go func() {
					b := make([]byte, 65536)
					for {
						n, err := up.Read(b)
						if err != nil {
							return
						}
						if dropping() {
							continue
						}
						data := append([]byte(nil), b[:n]...)
						time.AfterFunc(oneWay, func() { pc.WriteTo(data, from) })
					}
				}()
			}
			mu.Unlock()
			data := append([]byte(nil), b[:n]...)
			time.AfterFunc(oneWay, func() { up.Write(data) })
		}
	}()
	return pc.LocalAddr().String(), func() int {
		mu.Lock()
		defer mu.Unlock()
		return len(upstreams)
	}
}

// A front server (nginx at keepalive_requests or on reload, a CDN) retires its
// HTTP/2 connection with a graceful GOAWAY. HTTP/2 resends the posts it left
// unprocessed only when their bodies can be read again; otherwise the session ended.
func TestPacketUpSurvivesFrontServerGoAway(t *testing.T) {
	const oneWay = 40 * time.Millisecond
	var received atomic.Int64
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, freePort(t), &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
	}, func(conn stat.Connection) {
		go func() {
			defer conn.Close()
			b := make([]byte, 8)
			for {
				if _, err := io.ReadFull(conn, b); err != nil {
					return
				}
				received.Add(1)
			}
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	backend := &url.URL{Scheme: "http", Host: ln.Addr().String()}
	proxy := &httputil.ReverseProxy{Rewrite: func(r *httputil.ProxyRequest) { r.SetURL(backend) }, FlushInterval: -1}
	var fronts [2]*httptest.Server
	for i := range fronts {
		fronts[i] = httptest.NewUnstartedServer(proxy)
		fronts[i].EnableHTTP2 = true
		fronts[i].StartTLS()
		t.Cleanup(fronts[i].Close)
	}

	// The relay sends new connections to the second front once the first retires.
	relay, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { relay.Close() })
	var front atomic.Pointer[httptest.Server]
	front.Store(fronts[0])
	go func() {
		for {
			client, err := relay.Accept()
			if err != nil {
				return
			}
			server, err := gonet.Dial("tcp", front.Load().Listener.Addr().String())
			if err != nil {
				client.Close()
				continue
			}
			go delayCopy(server, client, oneWay, time.Time{})
			go delayCopy(client, server, oneWay, time.Time{})
		}
	}()

	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x","mode":"packet-up"}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true},
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	conn, err := splithttp.Dial(context.Background(), destination(t, relay.Addr().String()), client)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sent := 0
	b := make([]byte, 8)
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(10 * time.Millisecond) {
		if front.Load() == fronts[0] && time.Since(start) > time.Second {
			front.Store(fronts[1])
			go fronts[0].Config.Shutdown(context.Background())
		}
		if _, err := conn.Write(b); err != nil {
			t.Fatalf("write %d failed: %v", sent, err)
		}
		sent++
	}
	for deadline := time.Now().Add(5 * time.Second); received.Load() < int64(sent); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("received %d of %d packets", received.Load(), sent)
		}
	}
}

// While XMUX has fewer connections than it may (after it retired one, or at the start),
// the flow that found one missing paid for a new TCP and TLS handshake, three round trips
// here, although a warm connection was free. It takes the warm one; the new one is dialed ahead.
func TestXHTTPNewFlowTakesAWarmConnection(t *testing.T) {
	const oneWay = 50 * time.Millisecond
	relay, accepted := delayRelay(t, echoServer(t, false, nil), oneWay)
	client := xhttpClient(t, false, `{"path":"/x","mode":"stream-one"}`) // two TCP connections
	dest := destination(t, relay)
	if err := echo(dialXHTTP(t, context.Background(), dest, client), 1); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := echo(dialXHTTP(t, context.Background(), dest, client), 2); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed >= 4*oneWay {
		t.Fatalf("the second flow took %v; one round trip is %v", elapsed, 2*oneWay)
	}
	for deadline := time.Now().Add(2 * time.Second); accepted.Load() < 2; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the second connection was not dialed ahead")
		}
	}
}
