package tun

import (
	"context"
	"io"
	stdnet "net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
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
		net.UDPDestination(net.ParseAddress("198.18.0.3"), server), []byte("x"))
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
