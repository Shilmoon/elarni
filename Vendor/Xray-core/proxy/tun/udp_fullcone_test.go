package tun

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"testing"
	"time"

	appstats "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
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
				if !flow.IsValid() {
					flow = *mb[0].UDP
				}
				arrivals <- arrival{flow, *mb[0].UDP}
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

// A flow's queue takes memory only for waiting datagrams, holds as many as before (1024) and drops
// the next, keeps their order, and does not grow while its outbound keeps up.
func TestUDPQueueKeepsItsLimitAndOrder(t *testing.T) {
	var q packetQueue
	for i := range udpQueueLimit {
		if !q.push(buf.FromBytes([]byte{byte(i)})) {
			t.Fatalf("dropped datagram %d of %d", i, udpQueueLimit)
		}
	}
	if q.push(buf.New()) {
		t.Fatal("queued past the limit")
	}
	for i := range 10 * udpQueueLimit { // the outbound reads as fast as datagrams come
		if b := q.pop(); b.Bytes()[0] != byte(i) {
			t.Fatalf("datagram %d out of order", i)
		}
		if !q.push(buf.FromBytes([]byte{byte(i + udpQueueLimit)})) {
			t.Fatal("dropped a datagram while the queue had room")
		}
	}
	if cap(q.packets) > 2*udpQueueLimit {
		t.Fatalf("queue grew to %d slots", cap(q.packets))
	}
	q.close()
	for range udpQueueLimit {
		if q.pop() == nil {
			t.Fatal("close discarded datagrams queued before it")
		}
	}
	if q.pop() != nil || q.push(buf.New()) {
		t.Fatal("closed queue still works")
	}
}

// RFC 768: a computed UDP checksum of zero is sent as all ones; IPv6 receivers drop a zero checksum.
func TestUDPReplyChecksumIsNeverZero(t *testing.T) {
	device := &udpTestTun{endpoint: channel.New(1, 1500, "")}
	handler := &Handler{ctx: context.Background(), config: &Config{}, tun: device}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		t.Fatal(err)
	}
	if err := network.Start(); err != nil {
		t.Fatal(err)
	}
	handler.stack = network
	t.Cleanup(func() { handler.Close() })
	src := net.UDPDestination(net.ParseAddress("2001:db8::1"), 443)
	dst := net.UDPDestination(net.ParseAddress("2001:db8::2"), 40000)
	for i := range 1 << 16 {
		payload := []byte{byte(i >> 8), byte(i)}
		if err := network.(*stackGVisor).writeRawUDPPacket(payload, src, dst); err != nil {
			t.Fatal(err)
		}
		pkt := device.endpoint.Read()
		packet := pkt.ToView().AsSlice()
		pkt.DecRef()
		udp := header.UDP(packet[header.IPv6MinimumSize:])
		if udp.Checksum() == 0 {
			t.Fatalf("payload %x left with a zero checksum", payload)
		}
		ip := header.IPv6(packet)
		if !udp.IsChecksumValid(ip.SourceAddress(), ip.DestinationAddress(), checksum.Checksum(udp.Payload(), 0)) {
			t.Fatalf("payload %x left with an invalid checksum", payload)
		}
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

type udpTestTun struct {
	Tun
	endpoint *channel.Endpoint
}

func (t *udpTestTun) newEndpoint() (stack.LinkEndpoint, error) { return t.endpoint, nil }
func (t *udpTestTun) Close() error                             { t.endpoint.Close(); return nil }

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

func TestStackShutdownClosesUDPReader(t *testing.T) {
	device := &udpTestTun{endpoint: channel.New(1, 1500, "")}
	dispatcher := &udpTestDispatcher{link: make(chan *transport.Link, 1), done: make(chan struct{})}
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher, tun: device}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		t.Fatal(err)
	}
	handler.stack = network
	if err := network.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { handler.Close() })
	packet := make([]byte, 29)
	ip := header.IPv4(packet[:20])
	ip.Encode(&header.IPv4Fields{TotalLength: 29, TTL: 64, Protocol: 17})
	copy(packet[12:20], []byte{198, 18, 0, 2, 198, 18, 0, 3})
	ip.SetChecksum(^ip.CalculateChecksum())
	binary.BigEndian.PutUint16(packet[20:22], 40000)
	binary.BigEndian.PutUint16(packet[22:24], 50000)
	binary.BigEndian.PutUint16(packet[24:26], 9)
	packet[28] = 1
	input := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
	device.endpoint.InjectInbound(header.IPv4ProtocolNumber, input)
	input.DecRef()
	select {
	case link := <-dispatcher.link:
		t.Cleanup(func() { common.Close(link.Writer); <-dispatcher.done })
	case <-time.After(time.Second):
		t.Fatal("UDP session did not reach dispatcher")
	}
	if err := handler.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-dispatcher.done:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("closed stack retained a blocked UDP session")
	}
}
