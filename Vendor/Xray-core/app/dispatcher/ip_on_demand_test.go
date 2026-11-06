package dispatcher

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/pipe"
)

type countingDNS struct {
	lookups int
	hosts   map[string]net.IP
}

func (*countingDNS) Type() interface{} { return dns.ClientType() }
func (*countingDNS) Start() error      { return nil }
func (*countingDNS) Close() error      { return nil }
func (c *countingDNS) LookupIP(domain string, _ dns.IPOption) ([]net.IP, uint32, error) {
	c.lookups++
	if ip, ok := c.hosts[domain]; ok {
		return []net.IP{ip}, 60, nil
	}
	return nil, 0, dns.ErrEmptyResponse
}

type fakePool struct{}

func (fakePool) Type() interface{}                                    { return dns.FakeDNSEngine(nil) }
func (fakePool) Start() error                                         { return nil }
func (fakePool) Close() error                                         { return nil }
func (fakePool) GetFakeIPForDomain(string) []net.Address              { return nil }
func (fakePool) GetDomainFromFakeDNS(net.Address) string              { return "" }
func (fakePool) GetFakeIPForDomain3(string, bool, bool) []net.Address { return nil }
func (fakePool) IsIPInIPPool(ip net.Address) bool {
	return ip.Family().IsIP() && ip.IP()[0] == 198 && ip.IP()[1]&0xfe == 18
}

type taggedHandler struct {
	tag    string
	picked *string
}

func (h taggedHandler) Tag() string { return h.tag }
func (h taggedHandler) Dispatch(_ context.Context, link *transport.Link) {
	*h.picked = h.tag
	common.Interrupt(link.Reader)
	common.Close(link.Writer)
}
func (taggedHandler) Start() error                         { return nil }
func (taggedHandler) Close() error                         { return nil }
func (taggedHandler) SenderSettings() *serial.TypedMessage { return nil }
func (taggedHandler) ProxySettings() *serial.TypedMessage  { return nil }

type taggedHandlers struct{ picked *string }

func (taggedHandlers) Type() interface{} { return outbound.ManagerType() }
func (taggedHandlers) Start() error      { return nil }
func (taggedHandlers) Close() error      { return nil }
func (m taggedHandlers) GetHandler(tag string) outbound.Handler {
	return taggedHandler{tag: tag, picked: m.picked}
}
func (m taggedHandlers) GetDefaultHandler() outbound.Handler              { return m.GetHandler("default") }
func (taggedHandlers) AddHandler(context.Context, outbound.Handler) error { return nil }
func (taggedHandlers) RemoveHandler(context.Context, string) error        { return nil }
func (taggedHandlers) ListHandlers(context.Context) []outbound.Handler    { return nil }

// Elarni: IPOnDemand resolved the sniffed domain of every TUN connection before routing it, although
// the connection already had its real IP: a lookup on the connection's critical path, and IP rules
// judged on the name's addresses instead of the one being dialed. Names without an IP (proxy mode,
// FakeDNS) still resolve.
func TestIPOnDemandRoutesByTheRealIPAndResolvesOnlyNames(t *testing.T) {
	instance, err := core.New(&core.Config{})
	common.Must(err)
	ipRules, err := geodata.ParseIPRules([]string{"198.51.100.0/24"})
	common.Must(err)
	resolver := &countingDNS{hosts: map[string]net.IP{
		"direct-range.test": net.ParseIP("198.51.100.7"),
		"outside.test":      net.ParseIP("203.0.113.9"),
	}}
	var picked string
	handlers := taggedHandlers{picked: &picked}
	r := new(router.Router)
	common.Must(r.Init(context.Background(), &router.Config{
		DomainStrategy: router.Config_IpOnDemand,
		Rule: []*router.RoutingRule{
			{TargetTag: &router.RoutingRule_Tag{Tag: "direct"}, Ip: ipRules},
			{TargetTag: &router.RoutingRule_Tag{Tag: "proxy"}, Networks: []net.Network{net.Network_TCP}},
		},
	}, resolver, handlers, nil))
	d := &DefaultDispatcher{ohm: handlers, router: r, fdns: fakePool{}}

	for _, c := range []struct {
		name    string
		dest    net.Destination
		host    string
		want    string
		lookups int
	}{
		{"TUN to a direct IP, name outside", net.TCPDestination(net.ParseAddress("198.51.100.20"), 80), "outside.test", "direct", 0},
		{"TUN to an IP outside, name direct", net.TCPDestination(net.ParseAddress("203.0.113.10"), 80), "direct-range.test", "proxy", 0},
		{"FakeDNS address", net.TCPDestination(net.ParseAddress("198.18.0.5"), 80), "direct-range.test", "direct", 1},
		{"proxy-mode name", net.TCPDestination(net.DomainAddress("direct-range.test"), 80), "direct-range.test", "direct", 1},
	} {
		resolver.lookups, picked = 0, ""
		ctx := context.WithValue(context.Background(), core.XrayKey(1), instance)
		ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: "tun"})
		ctx = session.ContextWithContent(ctx, &session.Content{SniffingRequest: session.SniffingRequest{
			Enabled: true, RouteOnly: true, OverrideDestinationForProtocol: []string{"http", "tls", "quic", "fakedns"},
		}})
		reader, writer := pipe.New(pipe.WithoutSizeLimit())
		common.Must(writer.WriteMultiBuffer(buf.MergeBytes(nil, []byte("GET / HTTP/1.1\r\nHost: "+c.host+"\r\n\r\n"))))
		_, downlink := pipe.New(pipe.WithoutSizeLimit())
		common.Must(d.DispatchLink(ctx, c.dest, &transport.Link{Reader: reader, Writer: downlink}))
		if picked != c.want || resolver.lookups != c.lookups {
			t.Errorf("%s: routed to %q after %d lookups, want %q after %d", c.name, picked, resolver.lookups, c.want, c.lookups)
		}
	}
}
