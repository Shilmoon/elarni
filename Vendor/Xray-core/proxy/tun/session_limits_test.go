package tun

import (
	"context"
	"errors"
	"io"
	stdnet "net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
)

func idleClock(idle time.Duration) *activity {
	clock := &activity{}
	clock.last.Store(time.Now().Add(-idle).UnixNano())
	return clock
}

func TestSessionAdmissionBoundsConcurrentActiveSessions(t *testing.T) {
	s := sessionAdmission{limit: 3, minIdle: time.Minute}
	var accepted atomic.Int32
	var group sync.WaitGroup
	for i := 0; i < 100; i++ {
		group.Go(func() {
			if s.acquire(idleClock(0), func() { t.Error("evicted an active session") }) != nil {
				accepted.Add(1)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 3 || len(s.sessions) != 3 {
		t.Fatal("session limit not enforced")
	}
	var unlimited sessionAdmission
	for range 10 {
		if unlimited.acquire(idleClock(0), nil) == nil {
			t.Fatal("zero limit must not bound sessions")
		}
	}
}

// A full table must not refuse new flows while it holds sessions that went
// quiet; it drops the one that has been silent longest instead.
func TestSessionAdmissionEvictsLongestIdleSession(t *testing.T) {
	s := sessionAdmission{limit: 2, minIdle: time.Minute}
	var stopped []int
	admit := func(id int, clock *activity) *admittedSession {
		return s.acquire(clock, func() { stopped = append(stopped, id) })
	}
	busy := idleClock(90 * time.Second)
	oldest := admit(0, idleClock(2*time.Minute))
	admit(1, busy)
	fresh := admit(2, idleClock(0))
	if fresh == nil || len(stopped) != 1 || stopped[0] != 0 || len(s.sessions) != 2 {
		t.Fatalf("full table did not replace its longest idle session: stopped %v", stopped)
	}
	oldest.release() // The evicted flow's own cleanup must not free another slot.
	busy.touch()
	if admit(3, idleClock(0)) != nil || len(stopped) != 1 || len(s.sessions) != 2 {
		t.Fatal("full table evicted a session that was still active")
	}
	fresh.release()
	if admit(4, idleClock(0)) == nil || len(stopped) != 1 || len(s.sessions) != 2 {
		t.Fatal("released capacity not reusable")
	}
}

func echoLink(link *transport.Link) error {
	for {
		data, err := link.Reader.ReadMultiBuffer()
		if err != nil {
			return err
		}
		if err := link.Writer.WriteMultiBuffer(data); err != nil {
			return err
		}
	}
}

type udpFlowFixture struct {
	udp     *udpConnectionHandler
	replies chan net.Port // client port each reply returned to
	done    chan net.Port // client port of each finished session
}

// Each flow echoes until its session ends, so only admission and the TUN
// handler's own lifetime rules can close it.
func newUDPFlowFixture(t *testing.T, handler *Handler) *udpFlowFixture {
	f := &udpFlowFixture{replies: make(chan net.Port, 16), done: make(chan net.Port, 16)}
	handler.ctx, handler.config = context.Background(), &Config{}
	handler.dispatcher = &udpRoundTripDispatcher{dispatch: echoLink}
	f.udp = newUdpConnectionHandler(func(conn net.Conn, dst net.Destination) {
		handler.HandleConnection(conn, dst)
		f.done <- conn.(*udpConn).src.Port
	}, func(_ []byte, _, client net.Destination) error {
		f.replies <- client.Port
		return nil
	})
	t.Cleanup(f.udp.Close)
	return f
}

func (f *udpFlowFixture) exchange(t *testing.T, client, server net.Port) {
	t.Helper()
	f.udp.HandlePacket(net.UDPDestination(net.ParseAddress("198.18.0.2"), client),
		net.UDPDestination(net.ParseAddress("198.18.0.3"), server), buf.FromBytes([]byte("x")))
	select {
	case got := <-f.replies:
		if got != client {
			t.Fatalf("reply went to port %d, want %d", got, client)
		}
	case <-time.After(time.Second):
		t.Fatalf("flow from port %d got no reply", client)
	}
}

func (f *udpFlowFixture) finished(t *testing.T, client net.Port, within time.Duration) {
	t.Helper()
	select {
	case got := <-f.done:
		if got != client {
			t.Fatalf("session from port %d ended, want %d", got, client)
		}
	case <-time.After(within):
		t.Fatalf("session from port %d still holds its slot", client)
	}
}

func TestFullUDPTableAdmitsNewFlowByEvictingIdleOne(t *testing.T) {
	handler := &Handler{udpAdmission: sessionAdmission{limit: 1, minIdle: 50 * time.Millisecond}}
	f := newUDPFlowFixture(t, handler)
	f.exchange(t, 40000, 50000)
	time.Sleep(100 * time.Millisecond)
	f.exchange(t, 40001, 50000)
	f.finished(t, 40000, time.Second)
}

func TestFullTCPTableAdmitsNewConnectionByEvictingIdleOne(t *testing.T) {
	listener, err := stdnet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	handler := &Handler{ctx: context.Background(), config: &Config{},
		dispatcher:   &udpRoundTripDispatcher{dispatch: echoLink},
		tcpAdmission: sessionAdmission{limit: 1, minIdle: 50 * time.Millisecond}}
	open := func() (stdnet.Conn, chan struct{}) {
		client, err := stdnet.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		server, err := listener.Accept()
		if err != nil {
			t.Fatal(err)
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			handler.HandleConnection(server, net.TCPDestination(net.LocalHostIP, 443))
		}()
		t.Cleanup(func() { client.Close(); <-done })
		return client, done
	}
	echo := func(client stdnet.Conn) error {
		client.SetDeadline(time.Now().Add(time.Second))
		if _, err := client.Write([]byte("x")); err != nil {
			return err
		}
		_, err := io.ReadFull(client, make([]byte, 1))
		return err
	}
	first, firstDone := open()
	if err := echo(first); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	second, _ := open()
	if err := echo(second); err != nil {
		t.Fatalf("new connection refused while an idle one held the table: %v", err)
	}
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("evicted connection kept running")
	}
}

// Windows sends each DNS query from a fresh port, so a query must not hold its
// UDP slot for the whole connection idle timeout once it has been answered.
func TestDNSFlowsReleaseSoonAfterTheyGoQuiet(t *testing.T) {
	handler := &Handler{dnsIdle: 100 * time.Millisecond}
	f := newUDPFlowFixture(t, handler)
	f.exchange(t, 40000, 50000)
	for range 4 { // Traffic keeps a DNS flow open past its idle interval.
		f.exchange(t, 40001, 53)
		time.Sleep(50 * time.Millisecond)
	}
	if len(f.done) != 0 {
		t.Fatal("a session closed while it still carried traffic")
	}
	f.finished(t, 40001, 500*time.Millisecond)
	if len(handler.udpAdmission.sessions) != 1 {
		t.Fatal("quiet DNS flow kept its slot, or another flow lost its slot")
	}
}

// A QUIC connection the browser closed sends nothing more: its flow must end after the UDP idle
// interval, not hold its outbound for the connection idle timeout, while a flow with traffic stays.
func TestUDPFlowsEndAfterTheyGoQuiet(t *testing.T) {
	handler := &Handler{udpIdle: 150 * time.Millisecond}
	f := newUDPFlowFixture(t, handler)
	for range 4 { // a keepalive every 50 ms keeps the flow past its idle interval
		f.exchange(t, 40000, 443)
		time.Sleep(50 * time.Millisecond)
	}
	if len(f.done) != 0 {
		t.Fatal("a flow closed while it still carried traffic")
	}
	f.finished(t, 40000, time.Second)
	if len(handler.udpAdmission.sessions) != 0 {
		t.Fatal("quiet flow kept its slot")
	}
}

// fakeHeap makes admission read live heap live out of a limit of 100 until the test ends.
func fakeHeap(t *testing.T, live int64) *atomic.Int32 {
	reads := new(atomic.Int32)
	saved := readHeap
	readHeap = func() (int64, int64) { reads.Add(1); return live, 100 }
	heapCheck.next.Store(0)
	t.Cleanup(func() { readHeap = saved; heapCheck.next.Store(0); heapCheck.high.Store(false) })
	return reads
}

// Near Android's Go memory limit the GC takes up to half the CPU long before the session limits fill:
// admission must then treat the table as full, replacing an idle session or refusing while all are active.
func TestAdmissionTreatsTableAsFullUnderMemoryPressure(t *testing.T) {
	active := func() { t.Error("evicted an active session") }
	fakeHeap(t, 80) // below 85%: room as usual
	s := sessionAdmission{limit: 100, minIdle: time.Minute}
	var stopped int
	s.acquire(idleClock(2*time.Minute), func() { stopped++ })
	s.acquire(idleClock(0), active)

	reads := fakeHeap(t, 90)
	if s.acquire(idleClock(0), active) == nil || stopped != 1 || len(s.sessions) != 2 {
		t.Fatalf("past 85%% of the memory limit the idle session was not replaced: stopped %d, %d sessions", stopped, len(s.sessions))
	}
	if s.acquire(idleClock(0), active) != nil || len(s.sessions) != 2 {
		t.Fatal("past 85% of the memory limit a session was admitted while every session was active")
	}
	if reads.Load() != 1 {
		t.Fatalf("read the heap %d times within a second, want once", reads.Load())
	}
	var empty sessionAdmission
	empty.limit = 100
	if empty.acquire(idleClock(0), nil) == nil {
		t.Fatal("an empty table refused a session: it has nothing to make room from")
	}
	var unlimited sessionAdmission
	for range 3 {
		if unlimited.acquire(idleClock(0), nil) == nil {
			t.Fatal("an embedder without session limits got memory-aware admission")
		}
	}
}

// lingerDispatcher echoes until the app closes its side, then holds the session open like an outbound
// waiting out policy downlinkOnly, until the session is evicted or 2 s pass.
type lingerDispatcher struct{ routing.Dispatcher }

func (lingerDispatcher) DispatchLink(ctx context.Context, _ net.Destination, link *transport.Link) error {
	err := echoLink(link)
	select {
	case <-ctx.Done():
	case <-time.After(2 * time.Second):
	}
	return err
}

// Churning apps fill the table with connections they already closed (Elarni): a full table must replace
// one of those at once instead of refusing new connections while they linger.
func TestFullTCPTableReplacesConnectionTheAppClosed(t *testing.T) {
	listener, err := stdnet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: lingerDispatcher{},
		tcpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute, finishedIdle: 50 * time.Millisecond}}
	open := func() (*stdnet.TCPConn, chan struct{}) {
		client, err := stdnet.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		server, err := listener.Accept()
		if err != nil {
			t.Fatal(err)
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			handler.HandleConnection(server, net.TCPDestination(net.LocalHostIP, 443))
		}()
		t.Cleanup(func() { client.Close(); <-done })
		return client.(*stdnet.TCPConn), done
	}
	echo := func(client stdnet.Conn) error {
		client.SetDeadline(time.Now().Add(300 * time.Millisecond))
		if _, err := client.Write([]byte("x")); err != nil {
			return err
		}
		_, err := io.ReadFull(client, make([]byte, 1))
		return err
	}
	first, firstDone := open()
	if err := echo(first); err != nil {
		t.Fatal(err)
	}
	busy, _ := open() // refused: the table holds the first, still open connection
	if echo(busy) == nil {
		t.Fatal("full table admitted a connection while its only session was open")
	}
	first.CloseWrite()
	deadline := time.Now().Add(2 * time.Second)
	for {
		next, _ := open()
		if echo(next) == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("full table refused new connections while it held one the app had closed")
		}
	}
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("replaced connection kept running")
	}
}

// Android sends each lookup from a fresh port, and an answered query lingers for dnsSessionIdle: a full
// table must replace an answered DNS flow at once (Elarni), but keep unanswered and non-DNS flows.
func TestFullUDPTableReplacesAnsweredDNSFlow(t *testing.T) {
	send := func(f *udpFlowFixture, client, server net.Port) {
		f.udp.HandlePacket(net.UDPDestination(net.ParseAddress("198.18.0.2"), client),
			net.UDPDestination(net.ParseAddress("198.18.0.3"), server), buf.FromBytes([]byte("x")))
	}
	admitted := func(t *testing.T, h *Handler, n int) {
		t.Helper()
		for deadline := time.Now().Add(time.Second); ; time.Sleep(time.Millisecond) {
			h.udpAdmission.mu.Lock()
			got := len(h.udpAdmission.sessions)
			h.udpAdmission.mu.Unlock()
			if got == n {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("%d sessions admitted, want %d", got, n)
			}
		}
	}
	t.Run("answered", func(t *testing.T) {
		handler := &Handler{udpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute, finishedIdle: dnsFinishedIdle}}
		f := newUDPFlowFixture(t, handler)
		f.exchange(t, 40000, 53)
		f.exchange(t, 40001, 53) // at once: a lookup burst turns a full table over in milliseconds
		f.finished(t, 40000, time.Second)
		f.exchange(t, 40000, 53) // the replaced flow's port starts a new flow
		f.finished(t, 40001, time.Second)
	})
	t.Run("extra replies", func(t *testing.T) {
		handler := &Handler{udpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute}}
		f := newUDPFlowFixture(t, handler)
		handler.dispatcher = &udpRoundTripDispatcher{dispatch: func(link *transport.Link) error {
			for first := true; ; first = false {
				mb, err := link.Reader.ReadMultiBuffer()
				if err != nil {
					return err
				}
				if !first { // only the first query is answered, twice (a duplicate or forged reply)
					buf.ReleaseMulti(mb)
					continue
				}
				if err := link.Writer.WriteMultiBuffer(buf.MultiBuffer{mb[0], buf.FromBytes([]byte("y"))}); err != nil {
					return err
				}
			}
		}}
		f.exchange(t, 40000, 53)
		<-f.replies
		send(f, 40000, 53) // still unanswered: the extra reply must not count for it
		time.Sleep(50 * time.Millisecond)
		send(f, 40001, 53)
		f.finished(t, 40001, time.Second)
	})
	t.Run("unanswered", func(t *testing.T) {
		handler := &Handler{udpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute}}
		f := newUDPFlowFixture(t, handler)
		handler.dispatcher = &udpRoundTripDispatcher{dispatch: func(link *transport.Link) error {
			for {
				mb, err := link.Reader.ReadMultiBuffer()
				buf.ReleaseMulti(mb)
				if err != nil {
					return err
				}
			}
		}}
		send(f, 40000, 53)
		admitted(t, handler, 1)
		send(f, 40001, 53)
		f.finished(t, 40001, time.Second) // the new query is refused; the one awaiting its answer stays
	})
	t.Run("not DNS", func(t *testing.T) {
		handler := &Handler{udpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute}}
		f := newUDPFlowFixture(t, handler)
		f.exchange(t, 40000, 50000)
		send(f, 40001, 50000)
		f.finished(t, 40001, time.Second)
	})
}

// Admission retires an answered DNS flow while its session is still ending (Elarni): a query from the same
// port in that window must start a new flow instead of being queued to the old one and lost.
func TestRetiredDNSFlowPassesLaterQueriesToANewFlow(t *testing.T) {
	c := &udpConn{queue: newPacketQueue(1)}
	if queued, _ := c.enqueue(buf.New()); !queued || c.retireAnswered() {
		t.Fatal("retired a flow with an unanswered query")
	}
	c.answer(1)
	if !c.retireAnswered() {
		t.Fatal("answered flow not retired")
	}
	if queued, retired := c.enqueue(buf.New()); queued || !retired {
		t.Fatal("retired flow took another datagram")
	}

	f := newUDPFlowFixture(t, &Handler{})
	f.exchange(t, 40000, 53)
	f.udp.RLock()
	old := f.udp.udpConns[flowKey(net.UDPDestination(net.ParseAddress("198.18.0.2"), 40000), net.UDPDestination(net.ParseAddress("198.18.0.3"), 53))]
	f.udp.RUnlock()
	if old == nil || !old.retireAnswered() {
		t.Fatal("answered flow not retired")
	}
	f.exchange(t, 40000, 53)
	f.finished(t, 40000, time.Second) // the retired flow's session ends on its own
}

// An app that half-closes and keeps downloading is not finished while data still flows (Elarni):
// a full table refuses new connections rather than cut that download.
func TestFullTCPTableKeepsHalfClosedConnectionThatStillReceives(t *testing.T) {
	listener, err := stdnet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	streaming := make(chan struct{})
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: &streamDispatcher{done: streaming},
		tcpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute, finishedIdle: 300 * time.Millisecond}}
	open := func() *stdnet.TCPConn {
		client, err := stdnet.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		server, err := listener.Accept()
		if err != nil {
			t.Fatal(err)
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			handler.HandleConnection(server, net.TCPDestination(net.LocalHostIP, 443))
		}()
		t.Cleanup(func() { client.Close(); <-done })
		return client.(*stdnet.TCPConn)
	}
	first := open()
	first.CloseWrite() // the request is sent; the response streams for 2 s
	received := make(chan int)
	go func() {
		n, _ := io.Copy(io.Discard, first)
		received <- int(n)
	}()
	// Margins for loaded runners: a refusal may take a while to close, and the last probe ends
	// well before the download does (when the slot frees legitimately).
	for deadline := time.Now().Add(1200 * time.Millisecond); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		next := open()
		next.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		if _, err := next.Read(make([]byte, 1)); err == nil || !isTimeout(err) {
			// A refused connection is closed at once (EOF); an admitted one would wait on its echo.
			continue
		}
		t.Fatal("full table admitted a connection by cutting a download in progress")
	}
	<-streaming
	if n := <-received; n != streamBytes {
		t.Fatalf("download cut short: %d of %d bytes", n, streamBytes)
	}
}

const streamBytes = 200

// streamDispatcher waits for the app's EOF, then the first session sends streamBytes bytes over 2 s.
type streamDispatcher struct {
	routing.Dispatcher
	started atomic.Bool
	done    chan struct{}
}

func (d *streamDispatcher) DispatchLink(ctx context.Context, _ net.Destination, link *transport.Link) error {
	for {
		mb, err := link.Reader.ReadMultiBuffer()
		buf.ReleaseMulti(mb)
		if err != nil {
			break
		}
	}
	if !d.started.CompareAndSwap(false, true) {
		return nil
	}
	defer close(d.done)
	for i := 0; i < streamBytes; i++ {
		if link.Writer.WriteMultiBuffer(buf.MultiBuffer{buf.FromBytes([]byte{1})}) != nil {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

func isTimeout(err error) bool {
	var ne stdnet.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// The stack hands its TCP connections' data over in buffers; the admission wrapper must keep that path, or
// every byte is copied through Read and Write (Elarni: the gVisor-era wrapper hid it).
func TestTrackedConnectionKeepsBufferMethods(t *testing.T) {
	wrapped, _ := trackConn(&tcpConn{})
	if _, ok := wrapped.(buf.Reader); !ok {
		t.Fatal("tracked stack connection lost ReadMultiBuffer")
	}
	if _, ok := wrapped.(buf.Writer); !ok {
		t.Fatal("tracked stack connection lost WriteMultiBuffer")
	}
	plain, _ := trackConn(&stdnet.TCPConn{})
	if _, ok := plain.(buf.Reader); ok {
		t.Fatal("a plain connection must not claim buffer methods it lacks")
	}
}
