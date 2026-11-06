package dns

import (
	"context"
	"io"
	"testing"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/pipe"
	"golang.org/x/net/dns/dnsmessage"
)

type staticClient struct {
	ips []net.IP
	err error
}

func (staticClient) Type() interface{} { return dns.ClientType() }
func (staticClient) Start() error      { return nil }
func (staticClient) Close() error      { return nil }
func (c staticClient) LookupIP(string, dns.IPOption) ([]net.IP, uint32, error) {
	return c.ips, 60, c.err
}

type capturedMessages chan *buf.Buffer

func (c capturedMessages) WriteMessage(b *buf.Buffer) error {
	c <- b
	return nil
}

// Elarni: a lookup that failed for any reason but an rcode or an empty answer (every resolver timed
// out, the proxy was down) got no reply at all, so the app's stub resolver waited out its own
// timeout, often 5 s, before it tried again or failed over.
func TestHijackedQueriesAlwaysGetAnAnswer(t *testing.T) {
	for _, c := range []struct {
		name    string
		qType   dnsmessage.Type
		client  staticClient
		rCode   dnsmessage.RCode
		answers int
	}{
		{"resolvers timed out", dnsmessage.TypeA, staticClient{err: errors.New("returning nil for domain example.test").Base(errors.New("record not found"))}, dnsmessage.RCodeServerFailure, 0},
		{"NXDOMAIN", dnsmessage.TypeA, staticClient{err: errors.New("returning nil for domain example.test").Base(dns.RCodeError(dnsmessage.RCodeNameError))}, dnsmessage.RCodeNameError, 0},
		{"no records of this type", dnsmessage.TypeA, staticClient{err: dns.ErrEmptyResponse}, dnsmessage.RCodeSuccess, 0},
		// With queryStrategy UseIPv4 every AAAA query ends here: empty, not failed, so apps use the A answer.
		{"AAAA when only IPv4 is used", dnsmessage.TypeAAAA, staticClient{err: dns.ErrEmptyResponse}, dnsmessage.RCodeSuccess, 0},
		{"answered", dnsmessage.TypeA, staticClient{ips: []net.IP{net.ParseIP("192.0.2.1")}}, dnsmessage.RCodeSuccess, 1},
	} {
		messages := make(capturedMessages, 1)
		timer := signal.CancelAfterInactivity(context.Background(), func() {}, time.Minute)
		(&Handler{client: c.client}).handleIPQuery(7, c.qType, "example.test.", messages, timer)
		timer.SetTimeout(0)
		select {
		case b := <-messages:
			var msg dnsmessage.Message
			common.Must(msg.Unpack(b.Bytes()))
			if msg.ID != 7 || msg.RCode != c.rCode || len(msg.Answers) != c.answers || len(msg.Questions) != 1 {
				t.Errorf("%s: id %d rcode %v with %d answers and %d questions, want id 7 rcode %v with %d answers",
					c.name, msg.ID, msg.RCode, len(msg.Answers), len(msg.Questions), c.rCode, c.answers)
			}
		default:
			t.Errorf("%s: no answer", c.name)
		}
	}
}

type udpDialer struct{ upstream *net.UDPAddr }

func (d udpDialer) Dial(context.Context, net.Destination) (stat.Connection, error) {
	return net.DialUDP("udp", nil, d.upstream)
}
func (udpDialer) DestIpAddress() net.IP                                 { return nil }
func (udpDialer) SetOutboundGateway(context.Context, *session.Outbound) {}

type capturedWrites chan buf.MultiBuffer

func (c capturedWrites) WriteMultiBuffer(mb buf.MultiBuffer) error {
	c <- mb
	return nil
}

// The response side now reads only after a query dialed upstream; a query sent upstream must still
// get the upstream's reply back.
func TestQueriesSentUpstreamGetTheUpstreamReply(t *testing.T) {
	upstream, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	common.Must(err)
	defer upstream.Close()
	go func() {
		packet := make([]byte, 512)
		n, from, err := upstream.ReadFromUDP(packet)
		if err == nil {
			upstream.WriteToUDP(append([]byte("reply:"), packet[:n]...), from)
		}
	}()
	h := &Handler{client: staticClient{}, timeout: time.Minute, rules: []*DNSRule{{action: RuleAction_Direct}}}
	reader, writer := pipe.New(pipe.WithoutSizeLimit())
	defer writer.Close()
	replies := make(capturedWrites, 1)
	ctx := session.ContextWithOutbounds(context.Background(), []*session.Outbound{{Target: net.UDPDestination(net.ParseAddress("192.0.2.53"), 53)}})
	go h.Process(ctx, &transport.Link{Reader: reader, Writer: replies}, udpDialer{upstream.LocalAddr().(*net.UDPAddr)})
	query := testQuery()
	common.Must(writer.WriteMultiBuffer(buf.MergeBytes(nil, query)))
	select {
	case mb := <-replies:
		if got := mb.String(); got != "reply:"+string(query) {
			t.Fatalf("reply %q, want the upstream's", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no reply from upstream")
	}
}

func testQuery() []byte {
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 1, RecursionDesired: true})
	common.Must(builder.StartQuestions())
	common.Must(builder.Question(dnsmessage.Question{Name: dnsmessage.MustNewName("example.test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}))
	query, err := builder.Finish()
	common.Must(err)
	return query
}

type oneQueryReader struct{ query []byte }

func (r *oneQueryReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	if r.query == nil {
		return nil, io.EOF
	}
	b := buf.New()
	b.Write(r.query)
	r.query = nil
	return buf.MultiBuffer{b}, nil
}

// One app query answered from the local resolver, on a flow of its own as stub resolvers send them.
func BenchmarkLocallyAnsweredQueryFlow(b *testing.B) {
	query := testQuery()
	h := &Handler{client: staticClient{ips: []net.IP{net.ParseIP("192.0.2.1")}}, timeout: time.Minute}
	log.ReplaceWithSeverityLogger(log.Severity_Warning) // the app's default level
	b.ReportAllocs()
	for b.Loop() {
		ctx := session.ContextWithOutbounds(context.Background(), []*session.Outbound{{Target: net.UDPDestination(net.ParseAddress("192.0.2.53"), 53)}})
		link := &transport.Link{Reader: &oneQueryReader{query: query}, Writer: buf.Discard}
		h.Process(ctx, link, nil) // ends with the flow's canceled context, as every flow does
	}
}
