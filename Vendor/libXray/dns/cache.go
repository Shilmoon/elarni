package dns

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"net"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Xray's localhost name server keeps no cache, so every connection asked again (Elarni). And
// without a resolv.conf, as on Android, Go asks its two default servers twice each; both reach
// the one server here, so an unreachable server cost 4 timeouts (20 s) per name instead of 2.
const (
	cacheEntries   = 256
	maxCacheTTL    = 5 * time.Minute
	maxNegativeTTL = 30 * time.Second
	// Go asks the next server as soon as one times out.
	retryWindow = time.Second
)

var now = time.Now

type question struct {
	name  string // lower case
	qtype dnsmessage.Type
	class dnsmessage.Class
}

type cachedAnswer struct {
	reply   []byte
	expires time.Time
}

type timeout struct {
	address string
	at      time.Time
}

type answerCache struct {
	mu       sync.Mutex
	answers  map[question]cachedAnswer
	timeouts map[question]timeout
	swept    time.Time
}

func newAnswerCache() *answerCache {
	return &answerCache{answers: map[question]cachedAnswer{}, timeouts: map[question]timeout{}}
}

// lookup returns a copy of the cached reply, or whether another of Go's servers would only repeat
// the query this server just left unanswered.
func (c *answerCache) lookup(q question, address string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := now()
	if answer, ok := c.answers[q]; ok {
		if t.Before(answer.expires) {
			return slices.Clone(answer.reply), false
		}
		delete(c.answers, q)
	}
	last, ok := c.timeouts[q]
	return nil, ok && last.address != address && t.Sub(last.at) < retryWindow
}

func (c *answerCache) store(q question, id uint16, reply []byte) {
	ttl, matched := replyTTL(q, id, reply)
	if !matched {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.timeouts, q)
	if ttl <= 0 {
		return
	}
	t := now()
	if len(c.answers) >= cacheEntries {
		// A full cache takes new answers as old ones expire; one sweep a second keeps a miss O(1).
		if t.Sub(c.swept) < time.Second {
			return
		}
		c.swept = t
		for key, answer := range c.answers {
			if !t.Before(answer.expires) {
				delete(c.answers, key)
			}
		}
		if len(c.answers) >= cacheEntries {
			return
		}
	}
	c.answers[q] = cachedAnswer{reply: slices.Clone(reply), expires: t.Add(ttl)}
}

func (c *answerCache) timedOut(q question, address string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := now()
	if len(c.timeouts) >= cacheEntries {
		for key, last := range c.timeouts {
			if t.Sub(last.at) >= retryWindow {
				delete(c.timeouts, key)
			}
		}
		if len(c.timeouts) >= cacheEntries {
			return // Go's own retries still run
		}
	}
	c.timeouts[q] = timeout{address: address, at: t}
}

// replyTTL says whether reply answers query id for q, and for how long it may be reused.
func replyTTL(q question, id uint16, reply []byte) (time.Duration, bool) {
	var parser dnsmessage.Parser
	header, err := parser.Start(reply)
	if err != nil || header.ID != id || !header.Response {
		return 0, false
	}
	got, err := parser.Question()
	if err != nil || got.Type != q.qtype || got.Class != q.class || !strings.EqualFold(got.Name.String(), q.name) {
		return 0, false
	}
	if header.Truncated || header.RCode != dnsmessage.RCodeSuccess && header.RCode != dnsmessage.RCodeNameError || parser.SkipAllQuestions() != nil {
		return 0, true
	}
	ttl, answers := uint32(math.MaxUint32), 0
	for {
		answer, err := parser.AnswerHeader()
		if err == dnsmessage.ErrSectionDone {
			break
		}
		if err != nil || parser.SkipAnswer() != nil {
			return 0, true
		}
		ttl, answers = min(ttl, answer.TTL), answers+1
	}
	if header.RCode == dnsmessage.RCodeSuccess && answers > 0 {
		return min(time.Duration(ttl)*time.Second, maxCacheTTL), true
	}
	// RFC 2308: a missing name or record is cached for the SOA's minimum, and only with an SOA.
	for {
		authority, err := parser.AuthorityHeader()
		if err != nil {
			return 0, true
		}
		if authority.Type == dnsmessage.TypeSOA {
			soa, err := parser.SOAResource()
			if err != nil {
				return 0, true
			}
			return min(time.Duration(min(authority.TTL, soa.MinTTL))*time.Second, maxNegativeTTL), true
		}
		if parser.SkipAuthority() != nil {
			return 0, true
		}
	}
}

// cachedConn carries one UDP exchange of Go's resolver: one query, then reads until its reply.
// It dials only when the cache cannot answer.
type cachedConn struct {
	cache    *answerCache
	ctx      context.Context
	address  string
	dial     func(context.Context) (net.Conn, error)
	conn     net.Conn
	deadline time.Time
	asked    question
	id       uint16
	known    bool // asked is a parsed query
	reply    []byte
}

func parseQuery(b []byte) (question, uint16, bool) {
	var parser dnsmessage.Parser
	header, err := parser.Start(b)
	if err != nil || header.Response {
		return question{}, 0, false
	}
	q, err := parser.Question()
	return question{strings.ToLower(q.Name.String()), q.Type, q.Class}, header.ID, err == nil
}

func (c *cachedConn) Write(b []byte) (int, error) {
	if c.asked, c.id, c.known = parseQuery(b); c.known {
		reply, repeat := c.cache.lookup(c.asked, c.address)
		if reply != nil {
			binary.BigEndian.PutUint16(reply, c.id)
			c.reply = reply
			return len(b), nil
		}
		if repeat {
			// Reported like the timeout it repeats.
			return 0, &net.OpError{Op: "write", Net: "udp", Err: os.ErrDeadlineExceeded}
		}
	}
	if c.conn == nil {
		conn, err := c.dial(c.ctx)
		if err != nil {
			return 0, err
		}
		c.conn = conn
		if !c.deadline.IsZero() {
			_ = conn.SetDeadline(c.deadline)
		}
	}
	return c.conn.Write(b)
}

func (c *cachedConn) Read(b []byte) (int, error) {
	if c.reply != nil {
		n := copy(b, c.reply)
		c.reply = nil
		return n, nil
	}
	if c.conn == nil {
		return 0, net.ErrClosed
	}
	n, err := c.conn.Read(b)
	if c.known {
		var netErr net.Error
		if err == nil {
			c.cache.store(c.asked, c.id, b[:n])
		} else if errors.As(err, &netErr) && netErr.Timeout() {
			c.cache.timedOut(c.asked, c.address)
		}
	}
	return n, err
}

// ReadFrom and WriteTo make Go's resolver frame queries as datagrams; it calls only Read and Write.
func (c *cachedConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, err := c.Read(b)
	return n, c.RemoteAddr(), err
}

func (c *cachedConn) WriteTo(b []byte, _ net.Addr) (int, error) { return c.Write(b) }

func (c *cachedConn) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

func (c *cachedConn) LocalAddr() net.Addr {
	if c.conn == nil {
		return &net.UDPAddr{}
	}
	return c.conn.LocalAddr()
}

func (c *cachedConn) RemoteAddr() net.Addr {
	if c.conn == nil {
		return &net.UDPAddr{}
	}
	return c.conn.RemoteAddr()
}

func (c *cachedConn) SetDeadline(t time.Time) error {
	c.deadline = t
	if c.conn == nil {
		return nil
	}
	return c.conn.SetDeadline(t)
}

func (c *cachedConn) SetReadDeadline(t time.Time) error {
	if c.conn == nil {
		return nil
	}
	return c.conn.SetReadDeadline(t)
}

func (c *cachedConn) SetWriteDeadline(t time.Time) error {
	if c.conn == nil {
		return nil
	}
	return c.conn.SetWriteDeadline(t)
}
