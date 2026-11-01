package freedom

import (
	"context"
	"errors"
	"io"
	gonet "net"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/pipe"
)

type ipv4OnlyDialer struct {
	mu    sync.Mutex
	dials []net.Destination
}

func (d *ipv4OnlyDialer) Dial(ctx context.Context, dest net.Destination) (stat.Connection, error) {
	d.mu.Lock()
	d.dials = append(d.dials, dest)
	d.mu.Unlock()
	if dest.Address.Family().IsIPv6() {
		return nil, errors.New("connect: network is unreachable")
	}
	conn, err := gonet.Dial("tcp", dest.NetAddr())
	if err != nil {
		return nil, err
	}
	return conn.(stat.Connection), nil
}
func (*ipv4OnlyDialer) DestIpAddress() net.IP                                 { return nil }
func (*ipv4OnlyDialer) SetOutboundGateway(context.Context, *session.Outbound) {}

type loopbackResolver struct{ asked []dns.IPOption }

func (*loopbackResolver) Type() interface{} { return dns.ClientType() }
func (*loopbackResolver) Start() error      { return nil }
func (*loopbackResolver) Close() error      { return nil }
func (r *loopbackResolver) LookupIP(domain string, option dns.IPOption) ([]net.IP, uint32, error) {
	r.asked = append(r.asked, option)
	if domain == "dual.example" && option.IPv4Enable {
		return []net.IP{net.IP{127, 0, 0, 1}}, 60, nil
	}
	return nil, 0, dns.ErrEmptyResponse
}

// A TUN flow keeps its IPv6 destination when sniffing is route-only. On a host
// without IPv6 the direct dial must reach the sniffed domain over IPv4.
func TestDirectIPv6DialFallsBackToSniffedDomainOverIPv4(t *testing.T) {
	listener, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		// The session only ends after the uplink-only timeout, so read the payload rather than waiting for EOF.
		data := make([]byte, len("tls client hello"))
		if _, err := io.ReadFull(conn, data); err != nil {
			return
		}
		received <- string(data)
	}()
	port := net.Port(listener.Addr().(*gonet.TCPAddr).Port)

	h := new(Handler)
	if err := h.Init(&Config{}, policy.DefaultManager{}); err != nil {
		t.Fatal(err)
	}
	resolver := &loopbackResolver{}
	ctx := internet.ContextWithSystemDialerFeatures(context.Background(), func() (dns.Client, outbound.Manager) { return resolver, nil })
	ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{
		Target:      net.TCPDestination(net.ParseAddress("2001:db8::10"), port),
		RouteTarget: net.TCPDestination(net.DomainAddress("dual.example"), port),
	}})
	upReader, upWriter := pipe.New()
	downReader, downWriter := pipe.New()
	defer downReader.Interrupt()
	payload := buf.New()
	payload.WriteString("tls client hello")
	if err := upWriter.WriteMultiBuffer(buf.MultiBuffer{payload}); err != nil {
		t.Fatal(err)
	}
	upWriter.Close()
	dialer := &ipv4OnlyDialer{}
	done := make(chan error, 1)
	go func() { done <- h.Process(ctx, &transport.Link{Reader: upReader, Writer: downWriter}, dialer) }()
	select {
	case got := <-received:
		if got != "tls client hello" {
			t.Fatalf("server received %q", got)
		}
	case err := <-done:
		t.Fatalf("Process ended without reaching the IPv4 address: %v; dials %v", err, dialer.dials)
	case <-time.After(5 * time.Second):
		t.Fatalf("no connection; dials %v", dialer.dials)
	}
	dialer.mu.Lock()
	defer dialer.mu.Unlock()
	if len(dialer.dials) != 2 || !dialer.dials[0].Address.Family().IsIPv6() || dialer.dials[1].Address.String() != "127.0.0.1" {
		t.Fatalf("dials %v, want the IPv6 target then 127.0.0.1", dialer.dials)
	}
	if len(resolver.asked) != 1 || !resolver.asked[0].IPv4Enable || resolver.asked[0].IPv6Enable {
		t.Fatalf("resolver options %v, want one IPv4-only lookup", resolver.asked)
	}
}

// A redirect names the only destination: its failed IPv6 dial must not reach the sniffed domain.
func TestRedirectedIPv6DialKeepsItsDestination(t *testing.T) {
	h := new(Handler)
	redirect := &DestinationOverride{Server: &protocol.ServerEndpoint{Address: net.NewIPOrDomain(net.ParseAddress("2001:db8::99")), Port: 443}}
	if err := h.Init(&Config{DestinationOverride: redirect}, policy.DefaultManager{}); err != nil {
		t.Fatal(err)
	}
	resolver := &loopbackResolver{}
	ctx := internet.ContextWithSystemDialerFeatures(context.Background(), func() (dns.Client, outbound.Manager) { return resolver, nil })
	ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{
		Target:      net.TCPDestination(net.ParseAddress("2001:db8::10"), 443),
		RouteTarget: net.TCPDestination(net.DomainAddress("dual.example"), 443),
	}})
	upReader, upWriter := pipe.New()
	_, downWriter := pipe.New()
	upWriter.Close()
	dialer := &ipv4OnlyDialer{}
	if err := h.Process(ctx, &transport.Link{Reader: upReader, Writer: downWriter}, dialer); err == nil {
		t.Fatal("the redirect target is unreachable, yet Process succeeded")
	}
	for _, dial := range dialer.dials {
		if dial.Address != net.ParseAddress("2001:db8::99") {
			t.Fatalf("dials %v left the redirect target", dialer.dials)
		}
	}
}
