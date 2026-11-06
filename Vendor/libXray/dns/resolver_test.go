package dns

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// fakeDNS answers on loopback by name: *.ok.test has an A record (TTL 60) and no AAAA (SOA
// minimum 30), missing.test does not exist (SOA minimum 20), nosoa.test does not exist and
// names no SOA, zero.test has TTL 0, fail.test fails and silent.test never answers.
type fakeDNS struct {
	conn    net.PacketConn
	mu      sync.Mutex
	queries map[string]int // "name type"
}

func startFakeDNS(t testing.TB) *fakeDNS {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &fakeDNS{conn: conn, queries: map[string]int{}}
	t.Cleanup(func() { _ = conn.Close() })
	go server.serve()
	return server
}

func (s *fakeDNS) address() string { return s.conn.LocalAddr().String() }

func (s *fakeDNS) count(name string, qtype dnsmessage.Type) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.queries[name+" "+qtype.String()]
}

func (s *fakeDNS) serve() {
	buffer := make([]byte, 1500)
	for {
		n, from, err := s.conn.ReadFrom(buffer)
		if err != nil {
			return
		}
		var parser dnsmessage.Parser
		header, err := parser.Start(buffer[:n])
		if err != nil {
			continue
		}
		question, err := parser.Question()
		if err != nil {
			continue
		}
		name := strings.ToLower(question.Name.String())
		s.mu.Lock()
		s.queries[name+" "+question.Type.String()]++
		s.mu.Unlock()
		if reply := answer(header.ID, question, name); reply != nil {
			_, _ = s.conn.WriteTo(reply, from)
		}
	}
}

func answer(id uint16, question dnsmessage.Question, name string) []byte {
	rcode, ttl, soa := dnsmessage.RCodeSuccess, uint32(60), uint32(0)
	switch {
	case name == "silent.test.":
		return nil
	case name == "fail.test.":
		rcode = dnsmessage.RCodeServerFailure
	case name == "missing.test.":
		rcode, soa = dnsmessage.RCodeNameError, 20
	case name == "nosoa.test.":
		rcode = dnsmessage.RCodeNameError
	case name == "zero.test.":
		ttl = 0
	case strings.HasSuffix(name, ".ok.test."):
		if question.Type == dnsmessage.TypeAAAA {
			soa = 30
		}
	default:
		rcode = dnsmessage.RCodeNameError
	}
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, Response: true, RecursionAvailable: true, RCode: rcode})
	_ = builder.StartQuestions()
	_ = builder.Question(question)
	_ = builder.StartAnswers()
	if rcode == dnsmessage.RCodeSuccess && question.Type == dnsmessage.TypeA {
		_ = builder.AResource(dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: ttl}, dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}})
	}
	_ = builder.StartAuthorities()
	if soa > 0 {
		zone := dnsmessage.MustNewName("test.")
		_ = builder.SOAResource(dnsmessage.ResourceHeader{Name: zone, Type: dnsmessage.TypeSOA, Class: dnsmessage.ClassINET, TTL: 3600},
			dnsmessage.SOAResource{NS: zone, MBox: zone, Serial: 1, Refresh: 3600, Retry: 600, Expire: 86400, MinTTL: soa})
	}
	reply, _ := builder.Finish()
	return reply
}

func benchmarkLookups(b *testing.B, name func(int) string) {
	server := startFakeDNS(b)
	resolver, err := newResolver(server.address(), nil)
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	for i := 0; b.Loop(); i++ {
		if _, err := resolver.LookupIPAddr(context.Background(), name(i)); err != nil {
			b.Fatal(err)
		}
	}
}

// One name looked up again and again, as Xray's localhost name server does per connection.
func BenchmarkLookupSameName(b *testing.B) {
	benchmarkLookups(b, func(int) string { return "bench.ok.test." })
}

// Every lookup a new name: the cost the cache adds to a miss.
func BenchmarkLookupNewNames(b *testing.B) {
	benchmarkLookups(b, func(i int) string { return fmt.Sprintf("n%d.ok.test.", i) })
}

func setClock(t *testing.T, start time.Time) *time.Time {
	clock := start
	now = func() time.Time { return clock }
	t.Cleanup(func() { now = time.Now })
	return &clock
}

// Answers are reused for their TTL (at most 5 minutes), a missing name or record for its SOA
// minimum (at most 30 s), and failures, TTL 0 and negative answers without an SOA never.
func TestResolverReusesAnswersForTheirTTL(t *testing.T) {
	clock := setClock(t, time.Unix(1_700_000_000, 0))
	server := startFakeDNS(t)
	resolver, err := newResolver(server.address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	lookup := func(name string) error {
		_, err := resolver.LookupIPAddr(context.Background(), name)
		return err
	}
	asked := func(name string, qtype dnsmessage.Type, want int) {
		t.Helper()
		if got := server.count(name, qtype); got != want {
			t.Fatalf("%s %s asked %d times, want %d", name, qtype, got, want)
		}
	}
	for range 2 {
		if err := lookup("a.ok.test."); err != nil {
			t.Fatal(err)
		}
	}
	if err := lookup("A.Ok.TEST."); err != nil { // names are case-insensitive
		t.Fatal(err)
	}
	asked("a.ok.test.", dnsmessage.TypeA, 1)
	asked("a.ok.test.", dnsmessage.TypeAAAA, 1)
	*clock = clock.Add(31 * time.Second) // past the missing AAAA's SOA minimum, within the A's TTL
	_ = lookup("a.ok.test.")
	asked("a.ok.test.", dnsmessage.TypeA, 1)
	asked("a.ok.test.", dnsmessage.TypeAAAA, 2)
	*clock = clock.Add(30 * time.Second)
	_ = lookup("a.ok.test.")
	asked("a.ok.test.", dnsmessage.TypeA, 2)

	for range 2 {
		var dnsErr *net.DNSError
		if err := lookup("missing.test."); !errors.As(err, &dnsErr) || !dnsErr.IsNotFound {
			t.Fatalf("a cached missing name answered %v", err)
		}
	}
	asked("missing.test.", dnsmessage.TypeA, 1)
	*clock = clock.Add(21 * time.Second)
	_ = lookup("missing.test.")
	asked("missing.test.", dnsmessage.TypeA, 2)

	for _, name := range []string{"zero.test.", "nosoa.test.", "fail.test."} {
		_ = lookup(name)
		once := server.count(name, dnsmessage.TypeA)
		_ = lookup(name)
		if again := server.count(name, dnsmessage.TypeA); once == 0 || again != 2*once {
			t.Fatalf("%s was reused: asked %d then %d times", name, once, again)
		}
	}
}

func TestResolverCacheKeepsItsSizeAndIgnoresForeignReplies(t *testing.T) {
	clock := setClock(t, time.Unix(1_700_000_000, 0))
	cache := newAnswerCache()
	key := func(i int) question {
		return question{fmt.Sprintf("n%d.ok.test.", i), dnsmessage.TypeA, dnsmessage.ClassINET}
	}
	store := func(i int, id uint16) {
		q := key(i)
		cache.store(q, 7, answer(id, dnsmessage.Question{Name: dnsmessage.MustNewName(q.name), Type: q.qtype, Class: q.class}, q.name))
	}
	store(0, 8) // another query's ID: a forged or late reply
	if reply, _ := cache.lookup(key(0), ""); reply != nil {
		t.Fatal("a reply to another query was cached")
	}
	for i := range cacheEntries + 1 {
		store(i, 7)
		*clock = clock.Add(time.Millisecond)
	}
	if len(cache.answers) != cacheEntries {
		t.Fatalf("%d answers kept, want %d", len(cache.answers), cacheEntries)
	}
	if reply, _ := cache.lookup(key(0), ""); reply == nil {
		t.Fatal("the full cache dropped an answer that had not expired")
	}
	*clock = clock.Add(time.Minute) // all expired
	store(cacheEntries+1, 7)
	if reply, _ := cache.lookup(key(cacheEntries+1), ""); reply == nil || len(cache.answers) != 1 {
		t.Fatalf("the expired answers were not swept for a new one: %d kept", len(cache.answers))
	}
}

// Go's two default servers both reach the one server here: after a timeout, the duplicate
// fails at once, while Go's next attempt and later lookups still ask.
func TestResolverAsksAnUnansweringServerOncePerAttempt(t *testing.T) {
	clock := setClock(t, time.Unix(1_700_000_000, 0))
	server := startFakeDNS(t)
	resolver, err := newResolver(server.address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 9, RecursionDesired: true})
	_ = builder.StartQuestions()
	_ = builder.Question(dnsmessage.Question{Name: dnsmessage.MustNewName("silent.test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	query, _ := builder.Finish()
	exchange := func(address string, want int) {
		t.Helper()
		conn, err := resolver.Dial(context.Background(), "udp", address)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(50 * time.Millisecond))
		if _, err = conn.Write(query); err == nil {
			_, err = conn.Read(make([]byte, 1232))
		}
		var netErr net.Error
		if !errors.As(err, &netErr) || !netErr.Timeout() {
			t.Fatalf("%s: %v, want a timeout", address, err)
		}
		if got := server.count("silent.test.", dnsmessage.TypeA); got != want {
			t.Fatalf("%s: server asked %d times, want %d", address, got, want)
		}
	}
	exchange("127.0.0.1:53", 1)
	exchange("[::1]:53", 1)
	exchange("127.0.0.1:53", 2)
	exchange("[::1]:53", 2)
	*clock = clock.Add(2 * retryWindow)
	exchange("[::1]:53", 3)
}
