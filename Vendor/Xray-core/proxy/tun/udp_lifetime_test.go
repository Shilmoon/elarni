package tun

import (
	"context"
	"errors"
	stdnet "net"
	"testing"
	"time"

	appstats "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	featuredns "github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/routing"
	dnsproxy "github.com/xtls/xray-core/proxy/dns"
	"github.com/xtls/xray-core/proxy/freedom"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	"golang.org/x/net/dns/dnsmessage"
)

type udpIdlePolicy struct{ policy.DefaultManager }

func (udpIdlePolicy) ForLevel(uint32) policy.Session {
	p := policy.SessionDefault()
	p.Timeouts.ConnectionIdle = 200 * time.Millisecond
	return p
}

type udpIdleDNS struct{ featuredns.Client }

func (udpIdleDNS) LookupIP(string, featuredns.IPOption) ([]net.IP, uint32, error) {
	return []net.IP{net.IP{127, 0, 0, 7}}, 60, nil
}

type udpIdleDialer struct{ internet.Dialer }

func (udpIdleDialer) SetOutboundGateway(context.Context, *session.Outbound) {}
func (udpIdleDialer) Dial(ctx context.Context, dest net.Destination) (stat.Connection, error) {
	if dest.Address.String() != "127.0.0.1" {
		return nil, errors.New("fixture permits loopback only")
	}
	return (&internet.DefaultSystemDialer{}).Dial(ctx, nil, dest, nil)
}

type udpIdleDispatcher struct {
	routing.Dispatcher
	process func(context.Context, *transport.Link, internet.Dialer) error
}

func (d *udpIdleDispatcher) DispatchLink(ctx context.Context, dest net.Destination, link *transport.Link) error {
	ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{Target: dest, OriginalTarget: dest}})
	return d.process(ctx, link, udpIdleDialer{})
}

// An abandoned OS UDP socket sends no close packet. Real DNS/direct outbounds
// must expire it and admit the next source without increasing the global limit.
func TestUDPIdleOutboundsReleaseAdmission(t *testing.T) {
	for _, protocol := range []string{"dns", "direct"} {
		t.Run(protocol, func(t *testing.T) {
			dispatcher := &udpIdleDispatcher{}
			dest := net.UDPDestination(net.ParseAddress("192.0.2.53"), 53)
			payload := []byte("idle fixture")
			if protocol == "dns" {
				outbound := &dnsproxy.Handler{}
				if err := outbound.Init(&dnsproxy.Config{}, udpIdleDNS{}, udpIdlePolicy{}); err != nil {
					t.Fatal(err)
				}
				dispatcher.process = outbound.Process
				message := dnsmessage.Message{Header: dnsmessage.Header{ID: 42, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("fixture.invalid."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
				var err error
				payload, err = message.Pack()
				if err != nil {
					t.Fatal(err)
				}
			} else {
				outbound := &freedom.Handler{}
				if err := outbound.Init(&freedom.Config{}, udpIdlePolicy{}); err != nil {
					t.Fatal(err)
				}
				dispatcher.process = outbound.Process
				echo, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { echo.Close() })
				dest = net.DestinationFromAddr(echo.LocalAddr())
				go func() {
					data := make([]byte, 4096)
					for {
						n, peer, err := echo.ReadFrom(data)
						if err != nil {
							return
						}
						_, _ = echo.WriteTo(data[:n], peer)
					}
				}()
			}
			var up, down, sessions appstats.Counter
			handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher,
				uplinkCounter: &up, downlinkCounter: &down, udpSessions: &sessions, udpAdmission: sessionAdmission{limit: 1}}
			replies := make(chan []byte, 3)
			done := make(chan struct{}, 3)
			udp := newUdpConnectionHandler(func(conn net.Conn, dst net.Destination) {
				handler.HandleConnection(conn, dst)
				done <- struct{}{}
			}, func(data []byte, _, _ net.Destination) error {
				replies <- append([]byte(nil), data...)
				return nil
			})
			t.Cleanup(udp.Close)
			for i := range 3 {
				udp.HandlePacket(net.UDPDestination(net.ParseAddress("198.18.0.2"), net.Port(40000+i)), dest, buf.FromBytes(payload))
				select {
				case reply := <-replies:
					if protocol == "dns" {
						var message dnsmessage.Message
						if err := message.Unpack(reply); err != nil || !message.Response || len(message.Answers) != 1 {
							t.Fatalf("missing DNS answer: %v", err)
						}
					} else if string(reply) != string(payload) {
						t.Fatal("echo payload changed")
					}
				case <-time.After(time.Second):
					t.Fatal("new source could not exchange traffic")
				}
				// No explicit Close or cancellation before checking idle cleanup.
				select {
				case <-done:
				case <-time.After(300 * time.Millisecond):
					// The configured idle interval is 200ms. Allow scheduling slack,
					// but not a second full interval after a completed exchange.
					t.Fatal("abandoned source retained admission beyond its idle timeout")
				}
				if sessions.Value() != 0 || len(handler.udpAdmission.sessions) != 0 {
					t.Fatal("expired outbound retained its session count or capacity")
				}
			}
		})
	}
}
