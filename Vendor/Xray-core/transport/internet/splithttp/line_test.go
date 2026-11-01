package splithttp_test

import (
	"context"
	"encoding/json"
	"io"
	"math/rand/v2"
	gonet "net"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol/tls/cert"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

const (
	lineRate   = 29e6 / 8 // bytes per second, server to client
	oneWay     = 20 * time.Millisecond
	queueBytes = 64 << 10 // shared bottleneck buffer, about 18 ms at 29 Mbps
	chunkBytes = 16 << 10
)

// line emulates the access link. Server-to-client data from every connection
// goes through one rate-limited queue; connections take turns (round robin),
// like TCP flows sharing a bottleneck fairly. backlog is how much each
// connection may hold before the line (the server's unsent send buffer).
type line struct {
	backlog int
	rate    float64 // bytes per second
	oneWay  time.Duration

	mu       sync.Mutex
	cond     *sync.Cond
	conns    []*lineConn
	next     int
	nextFree time.Time
}

type lineConn struct {
	pending [][]byte
	queued  int
	deliver chan delivery
	closed  bool
}

type delivery struct {
	at   time.Time
	data []byte
}

func newLine(backlog int) *line {
	return newLineWith(lineRate, oneWay, backlog)
}

func newLineWith(rate float64, oneWay time.Duration, backlog int) *line {
	l := &line{backlog: max(backlog, chunkBytes), rate: rate, oneWay: oneWay}
	l.cond = sync.NewCond(&l.mu)
	go l.schedule()
	return l
}

func (l *line) schedule() {
	for {
		l.mu.Lock()
		var c *lineConn
		for c == nil {
			for i := range l.conns {
				candidate := l.conns[(l.next+i)%len(l.conns)]
				if len(candidate.pending) > 0 {
					c = candidate
					l.next = (l.next + i + 1) % len(l.conns)
					break
				}
			}
			if c == nil {
				l.cond.Wait()
			}
		}
		data := c.pending[0]
		c.pending = c.pending[1:]
		c.queued -= len(data)
		now := time.Now()
		start := l.nextFree
		if start.Before(now) {
			start = now
		}
		l.nextFree = start.Add(time.Duration(float64(len(data)) / l.rate * float64(time.Second)))
		wait := l.nextFree.Sub(now) - time.Duration(queueBytes/l.rate*float64(time.Second))
		c.deliver <- delivery{at: l.nextFree.Add(l.oneWay), data: data}
		l.cond.Broadcast()
		l.mu.Unlock()
		if wait > 0 {
			time.Sleep(wait)
		}
	}
}

// relay accepts client connections and forwards them to target through the line.
func (l *line) relay(t *testing.T, target string) string {
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			client, err := ln.Accept()
			if err != nil {
				return
			}
			server, err := gonet.Dial("tcp", target)
			if err != nil {
				client.Close()
				continue
			}
			// Keep the kernel's share of the backlog small so l.backlog decides it,
			// but above Linux loopback's 64 KB MSS, which stalls on delayed ACKs.
			server.(*gonet.TCPConn).SetReadBuffer(128 << 10)
			go l.serve(client, server)
		}
	}()
	return ln.Addr().String()
}

func (l *line) serve(client, server gonet.Conn) {
	closeBoth := sync.OnceFunc(func() { client.Close(); server.Close() })
	defer closeBoth()
	c := &lineConn{deliver: make(chan delivery, 4096)}
	l.mu.Lock()
	l.conns = append(l.conns, c)
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		c.closed = true
		l.conns = slices.DeleteFunc(l.conns, func(x *lineConn) bool { return x == c })
		l.next = 0
		l.cond.Broadcast()
		l.mu.Unlock()
	}()
	// Upload: delay only; the uplink is not the bottleneck in these tests.
	go func() {
		defer closeBoth()
		up := make(chan delivery, 4096)
		go func() {
			for d := range up {
				time.Sleep(time.Until(d.at))
				if _, err := server.Write(d.data); err != nil {
					closeBoth()
					return
				}
			}
		}()
		defer close(up)
		for {
			b := make([]byte, chunkBytes)
			n, err := client.Read(b)
			if n > 0 {
				up <- delivery{at: time.Now().Add(l.oneWay), data: b[:n]}
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		for d := range c.deliver {
			time.Sleep(time.Until(d.at))
			if _, err := client.Write(d.data); err != nil {
				closeBoth()
				return
			}
		}
	}()
	for {
		b := make([]byte, chunkBytes)
		n, err := server.Read(b)
		if n > 0 {
			l.mu.Lock()
			for c.queued+n > l.backlog && !c.closed {
				l.cond.Wait()
			}
			c.pending = append(c.pending, b[:n])
			c.queued += n
			l.cond.Broadcast()
			l.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// serveApp is the far end: 'B' streams bulk data, 'P' answers two requests,
// standing in for a TLS handshake and an HTTP request.
func serveApp(conn gonet.Conn) {
	defer conn.Close()
	cmd := make([]byte, probeRequest)
	if _, err := io.ReadFull(conn, cmd); err != nil {
		return
	}
	if cmd[0] == 'E' { // echo 64-byte messages, like DNS over one UDP flow
		msg := make([]byte, 64)
		for {
			if _, err := io.ReadFull(conn, msg); err != nil {
				return
			}
			if _, err := conn.Write(msg); err != nil {
				return
			}
		}
	}
	if cmd[0] == 'B' {
		data := make([]byte, 32<<10)
		for {
			if _, err := conn.Write(data); err != nil {
				return
			}
		}
	}
	for i, size := range probeReplies {
		if i > 0 {
			if _, err := io.ReadFull(conn, cmd); err != nil {
				return
			}
		}
		if _, err := conn.Write(make([]byte, size)); err != nil {
			return
		}
	}
	io.Copy(io.Discard, conn)
}

const probeRequest = 512

var probeReplies = []int{4096, 1024}

type transport struct {
	name string
	dial func(ctx context.Context) (gonet.Conn, error)
}

func certificate() *tls.Certificate {
	c, _ := cert.MustGenerate(nil, cert.DNSNames("localhost"), cert.CommonName("localhost"))
	parsed := tls.ParseCertificate(c)
	parsed.OneTimeLoading = true // the reload goroutine rewrites the certificate while handshakes read it
	return parsed
}

func listenXHTTP(t *testing.T, settings string) string {
	protocol := xhttpSettings(t, settings)
	stream := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: protocol,
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{Certificate: []*tls.Certificate{certificate()}},
	}
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, freePort(t), stream, func(conn stat.Connection) { go serveApp(conn) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String()
}

func xhttpSettings(t *testing.T, settings string) *splithttp.Config {
	var c conf.SplitHTTPConfig
	if err := json.Unmarshal([]byte(settings), &c); err != nil {
		t.Fatal(err)
	}
	built, err := c.Build()
	if err != nil {
		t.Fatal(err)
	}
	return built.(*splithttp.Config)
}

func xhttpTransport(t *testing.T, l *line, name, settings string) transport {
	relayAddr := l.relay(t, listenXHTTP(t, `{"path":"/x"}`))
	stream := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, settings),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true},
	}
	dest := destination(t, relayAddr)
	return transport{name: name, dial: func(ctx context.Context) (gonet.Conn, error) {
		return splithttp.Dial(ctx, dest, stream)
	}}
}

// freePort is needed because the Xray listeners treat port 0 as a unix socket. It picks a port
// below the ephemeral ranges (Linux 32768 and up, Windows and macOS 49152 and up): a port the
// system handed out could go to another test's outgoing connection before the listener binds it.
// The port is free for TCP and UDP, which XHTTP/3 listens on.
func freePort(t *testing.T) net.Port {
	t.Helper()
	for range 64 {
		port := 20000 + rand.IntN(12000)
		address := gonet.JoinHostPort("127.0.0.1", strconv.Itoa(port))
		tcp, err := gonet.Listen("tcp", address)
		if err != nil {
			continue
		}
		udp, err := gonet.ListenPacket("udp", address)
		tcp.Close()
		if err == nil {
			udp.Close()
			return net.Port(port)
		}
	}
	t.Fatal("no free port below the ephemeral range")
	return 0
}

func destination(t *testing.T, addr string) net.Destination {
	host, port, err := gonet.SplitHostPort(addr)
	if err != nil {
		t.Fatal(err)
	}
	p, _ := strconv.Atoi(port)
	return net.TCPDestination(net.ParseAddress(host), net.Port(p))
}

func percentile(ds []time.Duration, p float64) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	s := slices.Clone(ds)
	slices.Sort(s)
	return s[min(len(s)-1, int(p*float64(len(s))))]
}
