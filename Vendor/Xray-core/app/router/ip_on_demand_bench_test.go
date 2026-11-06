package router

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/dns"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

type cachedDNS struct{}

func (cachedDNS) Type() interface{} { return dns.ClientType() }
func (cachedDNS) Start() error      { return nil }
func (cachedDNS) Close() error      { return nil }
func (cachedDNS) LookupIP(string, dns.IPOption) ([]net.IP, uint32, error) {
	return []net.IP{net.ParseIP("203.0.113.9")}, 60, nil
}

// Routing a sniffed TUN connection with IPOnDemand, against a resolver that answers at once (the
// cheapest possible lookup, as from cache).
func BenchmarkIPOnDemandRouteOfASniffedTUNConnection(b *testing.B) {
	ipRules, err := geodata.ParseIPRules([]string{"198.51.100.0/24"})
	common.Must(err)
	r := new(Router)
	common.Must(r.Init(context.Background(), &Config{DomainStrategy: Config_IpOnDemand, Rule: []*RoutingRule{
		{TargetTag: &RoutingRule_Tag{Tag: "direct"}, Ip: ipRules},
		{TargetTag: &RoutingRule_Tag{Tag: "proxy"}, Networks: []net.Network{net.Network_TCP}},
	}}, cachedDNS{}, nil, nil))
	b.ReportAllocs()
	for b.Loop() {
		r.PickRoute(&routingsession.Context{Outbound: &session.Outbound{
			Target:      net.TCPDestination(net.ParseAddress("203.0.113.10"), 443),
			RouteTarget: net.TCPDestination(net.DomainAddress("outside.test"), 443),
		}})
	}
}
