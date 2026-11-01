package outbound

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/app/proxyman"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/pipe"
)

type fixedDNS struct{ ip net.IP }

func (fixedDNS) Type() any    { return dns.ClientType() }
func (fixedDNS) Start() error { return nil }
func (fixedDNS) Close() error { return nil }
func (d fixedDNS) LookupIP(string, dns.IPOption) ([]net.IP, uint32, error) {
	return []net.IP{d.ip}, 60, nil
}

type targetRecorder struct{ target net.Destination }

func (r *targetRecorder) Process(ctx context.Context, _ *transport.Link, _ internet.Dialer) error {
	outbounds := session.OutboundsFromContext(ctx)
	r.target = outbounds[len(outbounds)-1].Target
	return nil
}

// Android runs server tests in the VPN process: the process-wide DNS belongs to
// whichever core started last, so a target strategy must use its own core's DNS.
func TestTargetStrategyResolvesWithTheCoresOwnDNS(t *testing.T) {
	internet.InitSystemDialer(fixedDNS{net.IPAddress([]byte{127, 0, 0, 2}).IP()}, nil)
	t.Cleanup(func() { internet.InitSystemDialer(nil, nil) })
	recorder := &targetRecorder{}
	h := &Handler{senderSettings: &proxyman.SenderConfig{TargetStrategy: internet.DomainStrategy_FORCE_IP4}, proxy: recorder}
	ctx := internet.ContextWithSystemDialerFeatures(context.Background(), func() (dns.Client, outbound.Manager) {
		return fixedDNS{net.IPAddress([]byte{127, 0, 0, 1}).IP()}, nil
	})
	ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{Target: net.TCPDestination(net.DomainAddress("direct.test"), 443)}})
	reader, writer := pipe.New()
	h.Dispatch(ctx, &transport.Link{Reader: reader, Writer: writer})
	if got := recorder.target.Address.String(); got != "127.0.0.1" {
		t.Fatalf("resolved with another core's DNS: %s", got)
	}
}
