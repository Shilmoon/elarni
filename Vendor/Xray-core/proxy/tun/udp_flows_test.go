package tun

import (
	"bytes"
	"context"
	"errors"
	"net/netip"
	"testing"
	"time"

	appstats "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
)

type udpRoundTripDispatcher struct {
	routing.Dispatcher
	dispatch func(*transport.Link) error
}

func (d *udpRoundTripDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	return d.dispatch(link)
}

// Accounting must preserve the peer of each datagram when one browser socket
// talks to multiple destinations, including the source of each returning packet.
func TestUDPStatsPreservePacketDestinations(t *testing.T) {
	t.Run("small", func(t *testing.T) { testUDPStatsPreservePacketDestinations(t, []byte{42}) })
	t.Run("large", func(t *testing.T) { testUDPStatsPreservePacketDestinations(t, bytes.Repeat([]byte{42}, 32768)) })
}

func testUDPStatsPreservePacketDestinations(t *testing.T, payload []byte) {
	for _, withStats := range []bool{false, true} {
		name := "without_stats"
		if withStats {
			name = "with_stats"
		}
		t.Run(name, func(t *testing.T) {
			source := net.UDPDestination(net.ParseAddress("198.18.0.2"), 40000)
			peers := []net.Destination{
				net.UDPDestination(net.ParseAddress("198.18.0.3"), 50000),
				net.UDPDestination(net.ParseAddress("198.18.0.4"), 60000),
			}
			observed := make(chan *net.Destination, 2)
			replies := make(chan net.Destination, 2)
			done := make(chan struct{})
			var up, down, sessions appstats.Counter
			dispatcher := &udpRoundTripDispatcher{dispatch: func(link *transport.Link) error {
				for i := range peers {
					data, err := link.Reader.ReadMultiBuffer()
					if err != nil {
						return err
					}
					observed <- data[0].UDP
					// Supply the actual peer independently of the received metadata.
					data[0].UDP = &peers[i]
					if err := link.Writer.WriteMultiBuffer(data); err != nil {
						return err
					}
				}
				return nil
			}}
			handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher, udpSessions: &sessions}
			if withStats {
				handler.uplinkCounter, handler.downlinkCounter = &up, &down
			}
			udp := newUdpConnectionHandler(func(conn net.Conn, destination net.Destination) {
				defer close(done)
				handler.HandleConnection(conn, destination)
			}, func(data []byte, src, dst net.Destination) error {
				if !bytes.Equal(data, payload) || dst != source {
					return errors.New("reply payload or client changed")
				}
				replies <- src
				return nil
			})
			t.Cleanup(func() { udp.Close(); <-done })
			for _, peer := range peers {
				udp.HandlePacket(source, peer, buf.FromBytes(payload))
				select {
				case got := <-observed:
					if got == nil || *got != peer {
						t.Errorf("outgoing packet peer = %v, want %v", got, peer)
					}
				case <-time.After(time.Second):
					t.Fatal("outgoing packet stalled")
				}
				select {
				case got := <-replies:
					if got != peer {
						t.Errorf("reply peer = %v, want %v", got, peer)
					}
				case <-time.After(time.Second):
					t.Fatal("reply stalled")
				}
			}
			<-done
			if sessions.Value() != 0 {
				t.Fatal("completed roundtrip retained its session")
			}
			if want := int64(2 * len(payload)); withStats && (up.Value() != want || down.Value() != want) {
				t.Fatalf("byte counters = %d/%d, want %d/%d", up.Value(), down.Value(), want, want)
			}
		})
	}
}

func TestUDPClosingOldSessionPreservesReusedSource(t *testing.T) {
	connections := make(chan net.Conn, 3)
	handler := newUdpConnectionHandler(func(conn net.Conn, _ net.Destination) {
		connections <- conn
	}, func([]byte, net.Destination, net.Destination) error { return nil })
	src := net.UDPDestination(net.LocalHostIP, 40000)
	dst := net.UDPDestination(net.LocalHostIP, 50000)
	open := func() net.Conn {
		handler.HandlePacket(src, dst, buf.FromBytes([]byte("first")))
		select {
		case conn := <-connections:
			var data [16]byte
			if _, err := conn.Read(data[:]); err != nil {
				t.Fatal(err)
			}
			return conn
		case <-time.After(time.Second):
			t.Fatal("session did not start")
			return nil
		}
	}
	old := open()
	old.Close()
	current := open()
	defer current.Close()
	old.Close() // Outbound cleanup and Handler's deferred Close can both run.
	handler.HandlePacket(src, dst, buf.FromBytes([]byte("next")))
	var data [16]byte
	n, err := current.Read(data[:])
	if err != nil || string(data[:n]) != "next" {
		t.Fatalf("old Close interrupted replacement session: %q, %v", data[:n], err)
	}
}

func TestUDPWriteReportsDeviceFailure(t *testing.T) {
	want := errors.New("device closed")
	conn := &udpConn{handler: newUdpConnectionHandler(nil,
		func([]byte, net.Destination, net.Destination) error { return want })}
	if n, err := conn.Write([]byte("reply")); n != 0 || !errors.Is(err, want) {
		t.Fatalf("Write = %d, %v; want 0, device error", n, err)
	}
}

type udpTestDispatcher struct {
	routing.Dispatcher
	link chan *transport.Link
	done chan struct{}
}

func (d *udpTestDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	defer close(d.done)
	d.link <- link
	for {
		data, err := link.Reader.ReadMultiBuffer()
		buf.ReleaseMulti(data)
		if err != nil {
			return err
		}
	}
}

// Stopping the stack must end UDP sessions whose outbound still waits for packets (Elarni): they would
// otherwise hold their goroutines and slots until the connection idle timeout.
func TestStackShutdownClosesUDPReader(t *testing.T) {
	dispatcher := &udpTestDispatcher{link: make(chan *transport.Link, 1), done: make(chan struct{})}
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher}
	l := newLink()
	l.out = func([]byte) {}
	s := newTestStack(t, l, handler.HandleConnection)
	l.in <- udpPacket(netip.MustParseAddrPort("198.18.0.2:40000"), netip.MustParseAddrPort("198.18.0.3:50000"), []byte{1})
	select {
	case link := <-dispatcher.link:
		t.Cleanup(func() { common.Close(link.Writer) })
	case <-time.After(time.Second):
		t.Fatal("UDP session did not reach dispatcher")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-dispatcher.done:
	case <-time.After(time.Second):
		t.Fatal("closed stack retained a blocked UDP session")
	}
}

// Routing hijacks port 53 to the DNS outbound, which drops anything else. One app socket that sends DNS
// and other traffic must reach each through its own flow, routed by its own destination, whichever
// comes first; other destinations still share the socket's flow (full cone).
func TestUDPSocketGetsSeparateFlowForDNS(t *testing.T) {
	for _, dnsFirst := range []bool{true, false} {
		type arrival struct{ flow, peer net.Destination }
		arrivals := make(chan arrival, 8)
		handler := &Handler{ctx: context.Background(), config: &Config{}}
		handler.dispatcher = &udpRoundTripDispatcher{dispatch: func(link *transport.Link) error {
			var flow net.Destination
			for {
				mb, err := link.Reader.ReadMultiBuffer()
				if err != nil {
					return err
				}
				for _, b := range mb {
					if !flow.IsValid() {
						flow = *b.UDP
					}
					arrivals <- arrival{flow, *b.UDP}
				}
				buf.ReleaseMulti(mb)
			}
		}}
		udp := newUdpConnectionHandler(handler.HandleConnection, func([]byte, net.Destination, net.Destination) error { return nil })
		source := net.UDPDestination(net.ParseAddress("198.18.0.2"), 40000)
		dns := net.UDPDestination(net.ParseAddress("198.18.0.3"), 53)
		web := net.UDPDestination(net.ParseAddress("198.18.0.4"), 443)
		peer := net.UDPDestination(net.ParseAddress("198.18.0.5"), 3478)
		order := []net.Destination{web, dns, peer, web, dns}
		want := map[net.Destination]net.Destination{dns: dns, web: web, peer: web}
		if dnsFirst {
			order = []net.Destination{dns, web, peer, dns, web}
		}
		for _, dst := range order {
			udp.HandlePacket(source, dst, buf.FromBytes([]byte("x")))
			select {
			case got := <-arrivals:
				if got.peer != dst || got.flow != want[dst] {
					t.Errorf("DNS first %v: datagram to %v went to the flow of %v", dnsFirst, dst, got.flow)
				}
			case <-time.After(time.Second):
				t.Fatalf("DNS first %v: datagram to %v reached no flow", dnsFirst, dst)
			}
		}
		udp.Close()
	}
}
