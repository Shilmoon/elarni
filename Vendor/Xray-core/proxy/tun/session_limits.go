package tun

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/net"
)

var tcpLimit, udpLimit atomic.Int64

const (
	// A full table may replace a session this quiet; busier ones are never cut.
	sessionEvictIdle = 10 * time.Second
	// Stub resolvers retransmit within about 5 s, so a UDP port 53 flow that
	// quiet is finished; it need not hold its slot for the connection idle timeout.
	dnsSessionIdle = 5 * time.Second
	// How quiet a finished session must be before a full table replaces it (Elarni). It must stay below
	// a session's lifetime in a full table under churn (256 slots at 1,600 conn/s: 160 ms). DNS needs none:
	// retire hands a later query from the same port to a new flow.
	tcpFinishedIdle, dnsFinishedIdle = 50 * time.Millisecond, time.Duration(0)
)

// SetSessionLimits sets admission limits for subsequently created TUN handlers.
// Embedders that do not opt in retain unlimited sessions. Configure before Start.
func SetSessionLimits(tcp, udp int) {
	tcpLimit.Store(int64(tcp))
	udpLimit.Store(int64(udp))
}

// activity records when a session last carried traffic.
type activity struct {
	last atomic.Int64
	// done reports a flow whose work is over while its outbound still holds it open (Elarni): the app
	// closed it, or a DNS flow got all its answers. A full table replaces such a session first.
	done func() bool
	// retire claims a done flow for replacement; it fails when the flow came back to life (Elarni).
	retire func() bool
}

func (a *activity) touch()              { a.last.Store(time.Now().UnixNano()) }
func (a *activity) idle() time.Duration { return time.Duration(time.Now().UnixNano() - a.last.Load()) }
func (a *activity) finished() bool      { return a.done != nil && a.done() }
func (a *activity) claim() bool         { return a.retire == nil || a.retire() }

// activeConn records TCP traffic for idle eviction.
type activeConn struct {
	net.Conn
	activity
	closed atomic.Bool // the app closed its side: it sends no more
}

func newActiveConn(conn net.Conn) *activeConn {
	c := &activeConn{Conn: conn}
	c.done = c.closed.Load
	return c
}

func (c *activeConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.touch()
	if err != nil {
		c.closed.Store(true)
	}
	return n, err
}

func (c *activeConn) Write(b []byte) (int, error) {
	c.touch()
	return c.Conn.Write(b)
}

type sessionAdmission struct {
	limit   int64
	minIdle time.Duration
	// a finished session must be this quiet before a full table replaces it: a half-closed app may still
	// be receiving
	finishedIdle time.Duration
	mu           sync.Mutex
	sessions     map[*admittedSession]struct{}
}

type admittedSession struct {
	owner *sessionAdmission
	clock *activity
	stop  func()
}

// acquire admits a session, replacing a finished or else the longest idle one
// when the table is full. It returns nil when every admitted session is still active.
func (s *sessionAdmission) acquire(clock *activity, stop func()) *admittedSession {
	s.mu.Lock()
	var victim *admittedSession
	if s.limit != 0 && int64(len(s.sessions)) >= s.limit {
		finished := false
		for session := range s.sessions {
			if session.clock.finished() && session.clock.idle() >= s.finishedIdle && session.clock.claim() {
				victim, finished = session, true
				break
			}
			if victim == nil || session.clock.last.Load() < victim.clock.last.Load() {
				victim = session
			}
		}
		if !finished && victim.clock.idle() < s.minIdle {
			s.mu.Unlock()
			return nil
		}
		delete(s.sessions, victim)
	}
	if s.sessions == nil {
		s.sessions = make(map[*admittedSession]struct{})
	}
	session := &admittedSession{owner: s, clock: clock, stop: stop}
	s.sessions[session] = struct{}{}
	s.mu.Unlock()
	if victim != nil {
		victim.stop()
	}
	return session
}

// release frees the session's slot; it is a no-op once the session was evicted.
func (a *admittedSession) release() {
	a.owner.mu.Lock()
	delete(a.owner.sessions, a)
	a.owner.mu.Unlock()
}

func (a *admittedSession) evict() {
	a.release()
	a.stop()
}

// evictWhenIdle ends the session after idle without traffic; it returns early once done closes.
func (a *admittedSession) evictWhenIdle(done <-chan struct{}, idle time.Duration) {
	timer := time.NewTimer(idle)
	defer timer.Stop()
	for {
		select {
		case <-done:
			return
		case <-timer.C:
			if rest := idle - a.clock.idle(); rest > 0 {
				timer.Reset(rest)
				continue
			}
			a.evict()
			return
		}
	}
}
