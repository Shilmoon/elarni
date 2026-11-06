package dns

import (
	"context"
	"io"
	gonet "net"
	"net/http"
	"net/url"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/net/cnc"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/pipe"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/net/http2"
)

// answerA answers query with one A record, or returns nil when query does not parse.
func answerA(query []byte) []byte {
	var msg dnsmessage.Message
	if msg.Unpack(query) != nil || len(msg.Questions) != 1 {
		return nil
	}
	msg.Response = true
	msg.Answers = []dnsmessage.Resource{{
		Header: dnsmessage.ResourceHeader{Name: msg.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
		Body:   &dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}},
	}}
	answer, err := msg.Pack()
	common.Must(err)
	return answer
}

func shortPathChangeTimers(t *testing.T, settle, grace time.Duration) {
	previousSettle, previousGrace := pathChangeSettle, pathChangeGrace
	pathChangeSettle, pathChangeGrace = settle, grace
	t.Cleanup(func() { pathChangeSettle, pathChangeGrace = previousSettle, previousGrace })
}

func startedDNS(t *testing.T, server Server) {
	d := &DNS{clients: []*Client{{server: server}}}
	common.Must(d.Start())
	t.Cleanup(func() { d.Close() })
}

// dohServer is an h2c DoH server on loopback; serve answers each query on connection conn.
type dohServer struct {
	url    *url.URL
	opened chan int
	closed chan int
}

func startDoHServer(t *testing.T, serve func(conn int, query []byte) []byte) *dohServer {
	listener, err := gonet.Listen("tcp", "127.0.0.1:0")
	common.Must(err)
	t.Cleanup(func() { listener.Close() })
	s := &dohServer{
		url:    &url.URL{Scheme: "https", Host: listener.Addr().String(), Path: "/dns-query"},
		opened: make(chan int, 8),
		closed: make(chan int, 8),
	}
	go func() {
		for conn := 0; ; conn++ {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			s.opened <- conn
			go func() {
				defer func() { s.closed <- conn }()
				(&http2.Server{}).ServeConn(c, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					query, _ := io.ReadAll(r.Body)
					if answer := serve(conn, query); answer != nil {
						w.Header().Set("Content-Type", "application/dns-message")
						w.Write(answer)
					}
				})})
			}()
		}
	}()
	return s
}

func queryA(s Server, domain string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	ips, _, err := s.QueryIP(ctx, domain, dns.IPOption{IPv4Enable: true})
	if err == nil && len(ips) != 1 {
		err = dns.ErrEmptyResponse
	}
	return err
}

func receive(t *testing.T, c chan int, what string) int {
	t.Helper()
	select {
	case v := <-c:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("no %s", what)
		return 0
	}
}

// Elarni: after a network change DoH kept sending every query over its pooled HTTP/2 connection,
// which was left on the old path, so each query waited out its timeout until the connection's
// health check gave up (about a minute).
func TestDoHMovesNewQueriesOffADeadConnectionOnAPathChange(t *testing.T) {
	shortPathChangeTimers(t, 50*time.Millisecond, 100*time.Millisecond)
	var firstDead atomic.Bool
	server := startDoHServer(t, func(conn int, query []byte) []byte {
		if conn == 0 && firstDead.Load() {
			select {} // the old path swallows everything
		}
		return answerA(query)
	})
	s := NewDoHNameServer(server.url, nil, true, true, false, 0, nil)
	startedDNS(t, s)
	if err := queryA(s, "warm.test", 5*time.Second); err != nil {
		t.Fatal(err)
	}
	firstDead.Store(true)
	internet.SocketPathChanged()
	if err := queryA(s, "after.test", 2*time.Second); err != nil {
		t.Fatalf("query after the path change: %v", err)
	}
	if receive(t, server.opened, "first connection") != 0 || receive(t, server.opened, "fresh connection") != 1 {
		t.Fatal("unexpected connections")
	}
}

// A path change that turns out spurious must not drop what the healthy connection carries: its
// in-flight query still gets its answer, and the connection closes once it is idle.
func TestDoHPathChangeKeepsInFlightQueriesOfAHealthyConnection(t *testing.T) {
	shortPathChangeTimers(t, 50*time.Millisecond, time.Second)
	received, release := make(chan struct{}), make(chan struct{})
	server := startDoHServer(t, func(conn int, query []byte) []byte {
		if conn == 0 {
			close(received)
			<-release
		}
		return answerA(query)
	})
	s := NewDoHNameServer(server.url, nil, true, true, false, 0, nil)
	startedDNS(t, s)
	inFlight := make(chan error, 1)
	go func() { inFlight <- queryA(s, "slow.test", 5*time.Second) }()
	<-received
	internet.SocketPathChanged()
	if err := queryA(s, "after.test", 2*time.Second); err != nil {
		t.Fatalf("query after the path change: %v", err)
	}
	if receive(t, server.opened, "first connection") != 0 || receive(t, server.opened, "fresh connection") != 1 {
		t.Fatal("the query after the path change reused the old connection")
	}
	close(release)
	if err := <-inFlight; err != nil {
		t.Fatalf("in-flight query on the healthy connection: %v", err)
	}
	if conn := receive(t, server.closed, "close of the retired connection"); conn != 0 {
		t.Fatalf("connection %d closed, want the retired one", conn)
	}
}

type countingRetirer struct {
	Server
	retired chan time.Duration
}

func (r countingRetirer) retire(grace time.Duration) { r.retired <- grace }

// A burst of path change signals retires at once and once more when it settles, not once per signal.
func TestPathChangeBurstsRetireConnectionsAtMostTwice(t *testing.T) {
	shortPathChangeTimers(t, 50*time.Millisecond, time.Second)
	server := countingRetirer{retired: make(chan time.Duration, 16)}
	d := &DNS{clients: []*Client{{server: server}}}
	common.Must(d.Start())
	for range 5 {
		internet.SocketPathChanged()
	}
	if len(server.retired) != 1 {
		t.Fatalf("%d retires during the burst, want 1", len(server.retired))
	}
	time.Sleep(200 * time.Millisecond)
	if len(server.retired) != 2 {
		t.Fatalf("%d retires after the burst settled, want 2", len(server.retired))
	}
	common.Must(d.Close())
	internet.SocketPathChanged()
	if len(server.retired) != 2 {
		t.Fatal("a closed DNS still retired connections")
	}
}

// udpFlows is a routing.Dispatcher whose every Dispatch opens a flow that answer serves.
type udpFlows struct {
	opened atomic.Int32
	answer func(flow int, query []byte) []byte
	ended  chan int
}

func (*udpFlows) Type() interface{} { return nil }
func (*udpFlows) Start() error      { return nil }
func (*udpFlows) Close() error      { return nil }
func (*udpFlows) DispatchLink(context.Context, net.Destination, *transport.Link) error {
	return nil
}

func (f *udpFlows) Dispatch(_ context.Context, dest net.Destination) (*transport.Link, error) {
	flow := int(f.opened.Add(1)) - 1
	upReader, upWriter := pipe.New(pipe.WithoutSizeLimit())
	downReader, downWriter := pipe.New(pipe.WithoutSizeLimit())
	go func() {
		defer func() { f.ended <- flow }()
		for {
			mb, err := upReader.ReadMultiBuffer()
			if err != nil {
				return
			}
			for _, b := range mb {
				if answer := f.answer(flow, b.Bytes()); answer != nil {
					reply := buf.New()
					reply.Write(answer)
					reply.UDP = &dest
					downWriter.WriteMultiBuffer(buf.MultiBuffer{reply})
				}
			}
			buf.ReleaseMulti(mb)
		}
	}()
	return &transport.Link{Reader: downReader, Writer: upWriter}, nil
}

func udpTestContext(t *testing.T) context.Context {
	instance, err := core.New(&core.Config{})
	common.Must(err)
	return context.WithValue(context.Background(), core.XrayKey(1), instance)
}

func queryAWith(ctx context.Context, s Server, domain string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ips, _, err := s.QueryIP(ctx, domain, dns.IPOption{IPv4Enable: true})
	if err == nil && len(ips) != 1 {
		err = dns.ErrEmptyResponse
	}
	return err
}

// Elarni: a UDP query was sent once, so a lost datagram cost the whole query timeout, and the app's
// own retry joined the same lookup instead of sending another.
func TestUDPQueriesAreResentOnce(t *testing.T) {
	previous := udpResendAfter
	udpResendAfter = 50 * time.Millisecond
	t.Cleanup(func() { udpResendAfter = previous })
	var sent atomic.Int32
	flows := &udpFlows{ended: make(chan int, 8), answer: func(_ int, query []byte) []byte {
		if sent.Add(1) == 1 {
			return nil // lost
		}
		return answerA(query)
	}}
	s := NewClassicNameServer(net.UDPDestination(net.ParseAddress("192.0.2.53"), 53), flows, true, false, 0, nil)
	defer s.Close()
	if err := queryAWith(udpTestContext(t), s, "lossy.test", 2*time.Second); err != nil {
		t.Fatal(err)
	}
	if sent.Load() != 2 {
		t.Fatalf("%d datagrams sent, want 2", sent.Load())
	}
}

// After a path change new UDP queries take a fresh flow, and the old flow still delivers the answer
// to a query it carries, then closes.
func TestUDPPathChangeMovesNewQueriesAndKeepsInFlightAnswers(t *testing.T) {
	shortPathChangeTimers(t, 50*time.Millisecond, time.Second)
	previous := udpResendAfter
	udpResendAfter = time.Hour
	t.Cleanup(func() { udpResendAfter = previous })
	received, release := make(chan struct{}), make(chan struct{})
	flows := &udpFlows{ended: make(chan int, 8), answer: func(flow int, query []byte) []byte {
		if flow == 0 {
			close(received)
			<-release // a healthy but slow old path
		}
		return answerA(query)
	}}
	s := NewClassicNameServer(net.UDPDestination(net.ParseAddress("192.0.2.53"), 53), flows, true, false, 0, nil)
	startedDNS(t, s)
	ctx := udpTestContext(t)
	inFlight := make(chan error, 1)
	go func() { inFlight <- queryAWith(ctx, s, "slow.test", 5*time.Second) }()
	<-received
	internet.SocketPathChanged()
	if err := queryAWith(ctx, s, "after.test", 2*time.Second); err != nil {
		t.Fatalf("query after the path change: %v", err)
	}
	if flows.opened.Load() != 2 {
		t.Fatalf("%d flows, want a fresh one after the path change", flows.opened.Load())
	}
	close(release)
	if err := <-inFlight; err != nil {
		t.Fatalf("in-flight query on the old flow: %v", err)
	}
	if flow := receive(t, flows.ended, "end of the retired flow"); flow != 0 {
		t.Fatalf("flow %d ended, want the retired one", flow)
	}
}

// dohLinks is a routing.Dispatcher that hands each dial's far end to serve, as a proxy outbound would.
type dohLinks struct {
	dials atomic.Int32
	serve func(dial int, conn gonet.Conn)
}

func (*dohLinks) Type() interface{} { return nil }
func (*dohLinks) Start() error      { return nil }
func (*dohLinks) Close() error      { return nil }
func (*dohLinks) DispatchLink(context.Context, net.Destination, *transport.Link) error {
	return nil
}

func (d *dohLinks) Dispatch(context.Context, net.Destination) (*transport.Link, error) {
	upReader, upWriter := pipe.New(pipe.WithoutSizeLimit())
	downReader, downWriter := pipe.New(pipe.WithoutSizeLimit())
	far := cnc.NewConnection(cnc.ConnectionInputMulti(downWriter), cnc.ConnectionOutputMulti(upReader), cnc.ConnectionOnClose(downWriter))
	go d.serve(int(d.dials.Add(1))-1, far)
	return &transport.Link{Reader: downReader, Writer: upWriter}, nil
}

func serveDoH(conn gonet.Conn) {
	(&http2.Server{}).ServeConn(conn, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(answerA(query))
	})})
}

// A query that times out while its connection is still being set up through a slow proxy must not
// take the setup down with it: the next query uses the connection once it is ready.
func TestDoHQueryTimeoutLeavesTheConnectionBeingSetUp(t *testing.T) {
	ready := make(chan struct{})
	links := &dohLinks{serve: func(_ int, conn gonet.Conn) {
		<-ready // the proxy is still connecting
		serveDoH(conn)
	}}
	u, _ := url.Parse("https://dns.test/dns-query")
	s := NewDoHNameServer(u, links, true, true, false, 0, nil)
	defer s.Close()
	ctx := udpTestContext(t)
	if err := queryAWith(ctx, s, "early.test", 200*time.Millisecond); err == nil {
		t.Fatal("the query answered before the connection was ready")
	}
	close(ready)
	if err := queryAWith(ctx, s, "later.test", 5*time.Second); err != nil {
		t.Fatalf("query on the connection that finished setting up: %v", err)
	}
	if links.dials.Load() != 1 {
		t.Fatalf("%d dials, want the first connection reused", links.dials.Load())
	}
}

// Elarni: net/http sets a DoH connection up without any deadline, and later queries wait for that
// setup, so a TLS handshake stalled on a dead path held every query until the proxy link died.
func TestDoHAbandonsAStalledConnectionSetup(t *testing.T) {
	previous := dohSetupTimeout
	dohSetupTimeout = 500 * time.Millisecond
	t.Cleanup(func() { dohSetupTimeout = previous })
	closed := make(chan time.Duration, 4)
	links := &dohLinks{serve: func(_ int, conn gonet.Conn) {
		start := time.Now()
		io.Copy(io.Discard, conn) // a path that swallows the handshake
		closed <- time.Since(start)
	}}
	u, _ := url.Parse("https://dns.test/dns-query")
	s := NewDoHNameServer(u, links, false, true, false, 0, nil)
	defer s.Close()
	ctx := udpTestContext(t)
	queryAWith(ctx, s, "first.test", 100*time.Millisecond)
	select {
	case after := <-closed:
		if after < 300*time.Millisecond {
			t.Fatalf("the setup ended with the first query after %v, not after its own budget", after)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the stalled setup was never abandoned")
	}
	// The handshake closes the link before the transport drops the failed dial, so a query sent in
	// between shares that dial's error (seen on a loaded Windows VM); the next one dials afresh.
	for deadline := time.Now().Add(time.Second); links.dials.Load() < 2 && time.Now().Before(deadline); {
		queryAWith(ctx, s, "second.test", 200*time.Millisecond)
	}
	if links.dials.Load() != 2 {
		t.Fatalf("%d dials, want a fresh one after the stalled setup", links.dials.Load())
	}
}
