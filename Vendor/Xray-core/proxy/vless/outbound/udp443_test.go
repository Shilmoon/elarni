package outbound

import (
	"context"
	"strings"
	"testing"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/proxy/vless"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/pipe"
)

// countingDialer counts dials to the server and ends the attempt at once.
type countingDialer struct {
	dials  int
	cancel context.CancelFunc
}

func (d *countingDialer) Dial(context.Context, net.Destination) (stat.Connection, error) {
	d.dials++
	d.cancel()
	return nil, errors.New("test dial refused")
}
func (d *countingDialer) DestIpAddress() net.IP                                 { return nil }
func (d *countingDialer) SetOutboundGateway(context.Context, *session.Outbound) {}

// Elarni: Vision cannot carry UDP/443 (QUIC), so the outbound refuses it; it must do so before dialing,
// or each QUIC attempt costs the server a connection and a TLS/REALITY handshake for nothing.
func TestVisionRefusesUDP443BeforeDialing(t *testing.T) {
	for _, test := range []struct {
		name   string
		flow   string
		target net.Destination
		dials  bool
	}{
		{"vision QUIC", vless.XRV, net.UDPDestination(net.ParseAddress("www.google.com"), 443), false},
		{"vision QUIC by IP", vless.XRV, net.UDPDestination(net.ParseAddress("142.250.0.1"), 443), false},
		{"vision with UDP/443 allowed", vless.XRV + "-udp443", net.UDPDestination(net.ParseAddress("www.google.com"), 443), true},
		{"vision other UDP", vless.XRV, net.UDPDestination(net.ParseAddress("1.1.1.1"), 53), true},
		{"vision TCP/443", vless.XRV, net.TCPDestination(net.ParseAddress("www.google.com"), 443), true},
		{"no flow QUIC", "", net.UDPDestination(net.ParseAddress("www.google.com"), 443), true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := &Handler{server: &protocol.ServerSpec{
				Destination: net.TCPDestination(net.LocalHostIP, 443),
				User:        &protocol.MemoryUser{Account: &vless.MemoryAccount{Flow: test.flow}},
			}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{Target: test.target}})
			reader, writer := pipe.New()
			defer writer.Close()
			dialer := &countingDialer{cancel: cancel}
			err := h.Process(ctx, &transport.Link{Reader: reader, Writer: writer}, dialer)
			if err == nil {
				t.Fatal("Process succeeded without a server")
			}
			if got := dialer.dials > 0; got != test.dials {
				t.Fatalf("dialed %d times (%v), want dialing %v", dialer.dials, err, test.dials)
			}
			if !test.dials && !strings.Contains(err.Error(), "XTLS rejected UDP/443 traffic") {
				t.Fatalf("error %v", err)
			}
		})
	}
}
