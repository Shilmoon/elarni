package splithttp

import (
	"context"
	"io"
	gonet "net"
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal/done"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
)

type openConn struct{}

func (openConn) IsClosed() bool { return false }

// fullManager returns a manager whose TCP streams use every connection they
// may: all but the one kept for UDP flows.
func fullManager(connections int32) (*XmuxManager, []*XmuxClient) {
	m := NewXmuxManager(&XmuxConfig{MaxConnections: &RangeConfig{From: connections, To: connections}},
		func() XmuxConn { return openConn{} })
	var clients []*XmuxClient
	for range connections - 1 {
		clients = append(clients, m.GetXmuxClient(context.Background()))
	}
	return m, clients
}

func flowContext(network net.Network, port net.Port) context.Context {
	return session.ContextWithOutbounds(context.Background(), []*session.Outbound{{Target: net.Destination{
		Network: network, Address: net.ParseAddress("192.0.2.1"), Port: port}}})
}

func TestXmuxGivesUDPFlowsTheirOwnConnection(t *testing.T) {
	m, tcp := fullManager(3)
	if len(tcp) != 2 || tcp[0] == tcp[1] {
		t.Fatal("TCP streams did not get two connections")
	}
	udp := m.GetXmuxClient(flowContext(net.Network_UDP, 50000))
	if slices.Contains(tcp, udp) {
		t.Fatal("a UDP flow shares a connection with TCP streams")
	}
	for range 100 {
		if got := m.GetXmuxClient(flowContext(net.Network_UDP, 53)); got != udp {
			t.Fatal("UDP flows took more than one connection")
		}
		if got := m.GetXmuxClient(flowContext(net.Network_TCP, 443)); got == udp {
			t.Fatal("a TCP stream joined the UDP connection")
		}
		// QUIC carries downloads.
		if got := m.GetXmuxClient(flowContext(net.Network_UDP, 443)); got == udp {
			t.Fatal("a QUIC flow joined the UDP connection")
		}
	}
	if len(m.xmuxClients) != 3 {
		t.Fatalf("got %d connections, want 3", len(m.xmuxClients))
	}
}

func TestXmuxSharesTheOnlyConnection(t *testing.T) {
	m, _ := fullManager(1)
	tcp := m.GetXmuxClient(context.Background())
	if m.GetXmuxClient(flowContext(net.Network_UDP, 50000)) != tcp {
		t.Fatal("a UDP flow opened a connection beyond maxConnections 1")
	}
}

func TestXmuxAvoidsDownloadingConnections(t *testing.T) {
	m, clients := fullManager(4)
	now := time.Now()
	clients[0].noteDownload(1<<20, now)
	clients[1].noteDownload(1<<20, now)
	for range 100 {
		if got := m.GetXmuxClient(context.Background()); got != clients[2] {
			t.Fatalf("new stream went to connection %d, which is busy downloading", slices.Index(clients, got))
		}
	}
}

func TestXmuxKeepsConnectionCapWhenAllDownload(t *testing.T) {
	m, clients := fullManager(4)
	for _, c := range clients {
		c.noteDownload(1<<20, time.Now())
	}
	for range 100 {
		if got := m.GetXmuxClient(context.Background()); !slices.Contains(clients, got) {
			t.Fatal("opened a new connection beyond maxConnections")
		}
	}
	if len(m.xmuxClients) != 3 {
		t.Fatalf("got %d connections, want 3", len(m.xmuxClients))
	}
}

func TestXmuxDownloadActivityWindow(t *testing.T) {
	var c XmuxClient
	t0 := time.Now()
	c.noteDownload(busyBytes-1, t0)
	if c.busy(t0) {
		t.Fatal("a small download marked the connection busy")
	}
	c.noteDownload(1, t0.Add(time.Millisecond))
	if !c.busy(t0.Add(time.Millisecond)) {
		t.Fatal("a bulk download did not mark the connection busy")
	}
	if c.busy(t0.Add(time.Millisecond + busyWindow)) {
		t.Fatal("the busy mark did not expire")
	}
	// Bytes from an old window do not count toward a new one.
	c.noteDownload(busyBytes-1, t0.Add(3*busyWindow))
	if c.busy(t0.Add(3 * busyWindow)) {
		t.Fatal("bytes from an expired window still counted")
	}
}

// Dial must report the bytes it downloads to the connection that carries them.
func TestDialReportsDownloadToXmux(t *testing.T) {
	for _, mode := range []string{"packet-up", "stream-up", "stream-one"} {
		t.Run(mode, func(t *testing.T) { testDialReportsDownload(t, mode) })
	}
}

func testDialReportsDownload(t *testing.T, mode string) {
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := net.Port(ln.Addr().(*gonet.TCPAddr).Port)
	ln.Close()
	server := &internet.MemoryStreamConfig{ProtocolName: "splithttp", ProtocolSettings: &Config{Path: "/x"}}
	listener, err := ListenXH(context.Background(), net.LocalHostIP, port, server, func(conn stat.Connection) {
		go func() {
			defer conn.Close()
			io.ReadFull(conn, make([]byte, 1))
			conn.Write(make([]byte, 2*busyBytes))
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	client := &internet.MemoryStreamConfig{ProtocolName: "splithttp", ProtocolSettings: &Config{Path: "/x", Mode: mode}}
	conn, err := Dial(context.Background(), net.TCPDestination(net.LocalHostIP, port), client)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 2*busyBytes)); err != nil {
		t.Fatal(err)
	}
	globalDialerAccess.Lock()
	manager, found := globalDialerMap[dialerConf{net.TCPDestination(net.LocalHostIP, port), client}]
	globalDialerAccess.Unlock()
	if !found || !slices.ContainsFunc(manager.xmuxClients, func(c *XmuxClient) bool { return c.busy(time.Now()) }) {
		t.Fatal("downloaded bytes were not reported to the xmux connection")
	}
}

// Another dial can retire a connection before the session that got it starts running.
func TestRetiredClientStaysUsableForTheSessionThatGotIt(t *testing.T) {
	m := NewXmuxManager(&XmuxConfig{CMaxReuseTimes: &RangeConfig{From: 1, To: 1}}, func() XmuxConn {
		return &DefaultDialerClient{client: &http.Client{}, dialUploadConn: func(context.Context) (gonet.Conn, error) {
			ours, _ := gonet.Pipe()
			return ours, nil
		}}
	})
	a := m.holdXmuxClient(context.Background())
	m.holdXmuxClient(context.Background())
	a.AddRunning()
	if _, err := a.XmuxConn.(*DefaultDialerClient).uploadConn(context.Background()); err != nil {
		t.Fatalf("the client was closed under its session: %v", err)
	}
}

func TestGetExistingXmuxClient(t *testing.T) {
	xmuxConfig := &XmuxConfig{
		MaxConnections: &RangeConfig{From: 2, To: 2},
	}

	xmuxManager := NewXmuxManager(xmuxConfig, func() XmuxConn {
		return openConn{}
	})

	if xmuxManager.GetExistingXmuxClient(context.Background()) != nil {
		t.Error("got a client without creating one")
	}
	xmuxClient := xmuxManager.GetXmuxClient(context.Background())
	for i := 0; i < 4; i++ {
		if xmuxManager.GetExistingXmuxClient(context.Background()) != xmuxClient {
			t.Error("did not reuse the existing client")
		}
	}
}

// dialingConn is warm once up is set: a request on it finds its connection.
type dialingConn struct{ up *atomic.Bool }

func (dialingConn) IsClosed() bool { return false }
func (c dialingConn) warm() bool   { return c.up.Load() }

func dialingManager() (*XmuxManager, *[]*atomic.Bool, *int) {
	var ups []*atomic.Bool
	m := NewXmuxManager(&XmuxConfig{MaxConnections: &RangeConfig{From: 3, To: 3}}, func() XmuxConn {
		up := new(atomic.Bool)
		ups = append(ups, up)
		return dialingConn{up}
	})
	dials := 0
	m.preDial = func(context.Context, XmuxConn) *done.Instance { dials++; return done.New() }
	return m, &ups, &dials
}

// After a retirement the flow that found a connection missing paid for its handshake,
// although a warm connection was free.
func TestXmuxGivesNewFlowsAWarmConnectionWhileTheNextOneDials(t *testing.T) {
	m, ups, dials := dialingManager()
	warm := m.GetXmuxClient(context.Background())
	(*ups)[0].Store(true)
	if got := m.GetXmuxClient(context.Background()); got != warm || *dials != 1 {
		t.Fatalf("the second flow got a cold connection (%d pre-dials)", *dials)
	}
	for range 10 {
		if m.GetXmuxClient(context.Background()) != warm {
			t.Fatal("a flow got the connection still doing its handshake")
		}
	}
	(*ups)[1].Store(true)
	used := map[*XmuxClient]bool{}
	for range 64 {
		used[m.GetXmuxClient(context.Background())] = true
	}
	if len(used) != 2 || *dials != 1 {
		t.Fatalf("flows used %d connections after %d pre-dials, want 2 after 1", len(used), *dials)
	}
	(*ups)[1].Store(false) // the early connection expired unused
	for range 10 {
		if m.GetXmuxClient(context.Background()) != warm {
			t.Fatal("a flow got a connection that lost its early handshake while a warm one was free")
		}
	}
}

// A new connection is quicker than a warm one queued behind a download, and a connection
// that is not up is no warm one: packet-up moved its posts to it at once and they waited.
func TestXmuxTakesTheNewConnectionWhenNoWarmOneIsFree(t *testing.T) {
	m, ups, dials := dialingManager()
	first := m.GetXmuxClient(context.Background())
	if m.GetXmuxClient(context.Background()) == first || *dials != 0 {
		t.Fatal("a new flow was handed a connection that still needs its handshake")
	}
	m, ups, dials = dialingManager()
	first = m.GetXmuxClient(context.Background())
	(*ups)[0].Store(true)
	first.noteDownload(busyBytes, time.Now())
	if m.GetXmuxClient(context.Background()) == first || *dials != 0 {
		t.Fatal("a new flow queued behind a download while a new connection was due")
	}
}

// HTTP/3 requests beyond the server's stream limit wait for a stream until their response bound retires the connection.
func TestXmuxCapsSessionsPerHTTP3Connection(t *testing.T) {
	m := NewXmuxManager(&XmuxConfig{MaxConnections: &RangeConfig{From: 1, To: 1}}, func() XmuxConn { return openConn{} })
	m.sessionLimit = 2
	first := m.GetXmuxClient(context.Background())
	first.AddRunning()
	if m.GetXmuxClient(context.Background()) != first {
		t.Fatal("a connection under its session limit was not shared")
	}
	first.AddRunning()
	if m.GetXmuxClient(context.Background()) == first {
		t.Fatal("a connection at its session limit took another session")
	}
}

// A burst of network changes retires the pool once at its start and once at its end, not once per change.
func TestPathChangeBurstsCoalesce(t *testing.T) {
	t.Cleanup(SetPathChangeTiming(time.Second, 200*time.Millisecond))
	m := NewXmuxManager(&XmuxConfig{MaxConnections: &RangeConfig{From: 1, To: 1}}, func() XmuxConn { return openConn{} })
	key := dialerConf{MemoryStreamConfig: &internet.MemoryStreamConfig{}}
	globalDialerAccess.Lock()
	if globalDialerMap == nil {
		globalDialerMap = map[dialerConf]xmuxDialer{}
	}
	globalDialerMap[key] = xmuxDialer{m, func() {}}
	globalDialerAccess.Unlock()
	t.Cleanup(func() {
		globalDialerAccess.Lock()
		delete(globalDialerMap, key)
		globalDialerAccess.Unlock()
	})
	client := func() *XmuxClient {
		globalDialerAccess.Lock()
		defer globalDialerAccess.Unlock()
		return m.GetXmuxClient(context.Background())
	}
	first := client()
	socketPathChanged()
	if !first.NotUsed.Load() {
		t.Fatal("the first change left the old connection in use")
	}
	second := client()
	for range 5 {
		socketPathChanged()
	}
	if second.NotUsed.Load() {
		t.Fatal("a change during the burst retired the pool again at once")
	}
	for deadline := time.Now().Add(time.Second); !second.NotUsed.Load(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the end of the burst did not retire the connections dialed during it")
		}
	}
	third := client()
	time.Sleep(500 * time.Millisecond) // two more windows
	if third.NotUsed.Load() {
		t.Fatal("the burst retired the pool a third time")
	}
}
