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
)

// SetSessionLimits sets admission limits for subsequently created TUN handlers.
// Embedders that do not opt in retain unlimited sessions. Configure before Start.
func SetSessionLimits(tcp, udp int) {
	tcpLimit.Store(int64(tcp))
	udpLimit.Store(int64(udp))
}

// activity records when a session last carried traffic.
type activity struct{ last atomic.Int64 }

func (a *activity) touch()              { a.last.Store(time.Now().UnixNano()) }
func (a *activity) idle() time.Duration { return time.Duration(time.Now().UnixNano() - a.last.Load()) }

// activeConn records TCP traffic for idle eviction.
type activeConn struct {
	net.Conn
	activity
}

func (c *activeConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.touch()
	return n, err
}

func (c *activeConn) Write(b []byte) (int, error) {
	c.touch()
	return c.Conn.Write(b)
}

type sessionAdmission struct {
	limit    int64
	minIdle  time.Duration
	mu       sync.Mutex
	sessions map[*admittedSession]struct{}
}

type admittedSession struct {
	owner *sessionAdmission
	clock *activity
	stop  func()
}

// acquire admits a session, replacing the longest idle one when the table is
// full. It returns nil when every admitted session is still active.
func (s *sessionAdmission) acquire(clock *activity, stop func()) *admittedSession {
	s.mu.Lock()
	var victim *admittedSession
	if s.limit != 0 && int64(len(s.sessions)) >= s.limit {
		for session := range s.sessions {
			if victim == nil || session.clock.last.Load() < victim.clock.last.Load() {
				victim = session
			}
		}
		if victim.clock.idle() < s.minIdle {
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
