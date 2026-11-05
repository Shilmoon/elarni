package tun

import (
	"context"
	"encoding/binary"
	"testing"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// udpDatagram builds an IPv4 UDP packet from 198.18.0.2:40000 to 198.18.0.3:50000 (no UDP checksum).
func udpDatagram(payload int) []byte {
	packet := make([]byte, header.IPv4MinimumSize+header.UDPMinimumSize+payload)
	ip := header.IPv4(packet)
	ip.Encode(&header.IPv4Fields{TotalLength: uint16(len(packet)), TTL: 64, Protocol: 17})
	copy(packet[12:20], []byte{198, 18, 0, 2, 198, 18, 0, 3})
	ip.SetChecksum(^ip.CalculateChecksum())
	binary.BigEndian.PutUint16(packet[20:22], 40000)
	binary.BigEndian.PutUint16(packet[22:24], 50000)
	binary.BigEndian.PutUint16(packet[24:26], uint16(header.UDPMinimumSize+payload))
	return packet
}

// countingDispatcher hands its link out, then reads and frees datagrams, reporting each batch.
type countingDispatcher struct {
	routing.Dispatcher
	link  chan *transport.Link
	batch int
	read  chan struct{}
}

func (d *countingDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	d.link <- link
	for n := 0; ; {
		mb, err := link.Reader.ReadMultiBuffer()
		n += len(mb)
		buf.ReleaseMulti(mb)
		if err != nil {
			return err
		}
		if n >= d.batch {
			n -= d.batch
			d.read <- struct{}{}
		}
	}
}

func benchmarkUDPStack(b *testing.B, batch int) (*channel.Endpoint, *countingDispatcher) {
	device := &udpTestTun{endpoint: channel.New(1, 1500, "")}
	dispatcher := &countingDispatcher{link: make(chan *transport.Link, 1), batch: batch, read: make(chan struct{}, 1)}
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher, tun: device}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		b.Fatal(err)
	}
	handler.stack = network
	if err := network.Start(); err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { handler.Close() })
	return device.endpoint, dispatcher
}

func inject(endpoint *channel.Endpoint, packet []byte) {
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
	endpoint.InjectInbound(header.IPv4ProtocolNumber, pkt)
	pkt.DecRef()
}

// Datagrams from the app to the outbound, in batches the flow's queue holds whole.
func BenchmarkUDPUplink(b *testing.B) {
	const batch = 64
	endpoint, dispatcher := benchmarkUDPStack(b, batch)
	packet := udpDatagram(1200)
	inject(endpoint, packet)
	<-dispatcher.link
	for range batch - 1 {
		inject(endpoint, packet)
	}
	<-dispatcher.read
	b.SetBytes(1200)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i += batch {
		for range batch {
			inject(endpoint, packet)
		}
		<-dispatcher.read
	}
}

// firstDatagramDispatcher ends each flow once its first datagram arrived.
type firstDatagramDispatcher struct {
	routing.Dispatcher
	read chan struct{}
}

func (d *firstDatagramDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	mb, err := link.Reader.ReadMultiBuffer()
	buf.ReleaseMulti(mb)
	d.read <- struct{}{}
	return err
}

// One short flow per new app socket, as browsers and DNS lookups open them.
func BenchmarkUDPNewFlow(b *testing.B) {
	device := &udpTestTun{endpoint: channel.New(1, 1500, "")}
	dispatcher := &firstDatagramDispatcher{read: make(chan struct{})}
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher, tun: device}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		b.Fatal(err)
	}
	handler.stack = network
	if err := network.Start(); err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { handler.Close() })
	packet := udpDatagram(100)
	b.ReportAllocs()
	for i := range b.N {
		binary.BigEndian.PutUint16(packet[20:22], uint16(1024+i%60000)) // a new source port each time
		inject(device.endpoint, packet)
		<-dispatcher.read
	}
}

// Replies from the outbound back into the TUN device.
func BenchmarkUDPDownlink(b *testing.B) {
	endpoint, dispatcher := benchmarkUDPStack(b, 1<<30)
	inject(endpoint, udpDatagram(1))
	link := <-dispatcher.link
	peer := net.UDPDestination(net.ParseAddress("198.18.0.3"), 50000)
	payload := make([]byte, 1200)
	b.SetBytes(1200)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		reply := buf.New()
		reply.Write(payload)
		reply.UDP = &peer
		if err := link.Writer.WriteMultiBuffer(buf.MultiBuffer{reply}); err != nil {
			b.Fatal(err)
		}
		endpoint.Read().DecRef()
	}
}
