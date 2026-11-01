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
				udp.HandlePacket(source, peer, payload)
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
		handler.HandlePacket(src, dst, []byte("first"))
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
	handler.HandlePacket(src, dst, []byte("next"))
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
