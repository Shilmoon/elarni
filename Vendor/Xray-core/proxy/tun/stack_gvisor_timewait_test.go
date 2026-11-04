package tun

import (
	"context"
	"io"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// pump moves every packet one link writes into the other, as the TUN device does between an app and the stack.
func pump(ctx context.Context, from, to *channel.Endpoint) {
	for {
		pkt := from.ReadContext(ctx)
		if pkt == nil {
			return
		}
		to.InjectInbound(ipv4.ProtocolNumber, stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithView(pkt.ToView())}))
		pkt.DecRef()
	}
}

// When the stack closes a connection first (a blocked site, a server that closes), its endpoint enters TIME_WAIT
// while the app's kernel frees the port at once and may reuse it. The forwarder has no listening endpoint, so a SYN
// that meets that TIME_WAIT is dropped and the app's connect hangs until the TIME_WAIT ends (60 s by default).
func TestStackAcceptsSynReusingPortItClosedFirst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tunSide, appSide := channel.New(256, 1500, ""), channel.New(256, 1500, "")
	network, err := createStack(tunSide)
	if err != nil {
		t.Fatal(err)
	}
	defer network.Close()
	forwarder := tcp.NewForwarder(network, 0, 65535, func(r *tcp.ForwarderRequest) {
		ep, err := r.CreateEndpoint(new(waiter.Queue))
		if err != nil {
			r.Complete(true)
			return
		}
		ep.Close()
		r.Complete(false)
	})
	network.SetTransportProtocolHandler(tcp.ProtocolNumber, forwarder.HandlePacket)

	app := stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol}})
	defer app.Close()
	if err := app.CreateNIC(1, appSide); err != nil {
		t.Fatal(err)
	}
	local := tcpip.AddrFrom4([4]byte{10, 0, 0, 1})
	if err := app.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: local.WithPrefix()}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	app.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	go pump(ctx, tunSide, appSide)
	go pump(ctx, appSide, tunSide)

	from := tcpip.FullAddress{NIC: 1, Addr: local, Port: 40000}
	to := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{203, 0, 113, 10}), Port: 443}
	dial := func(wait time.Duration) error {
		dialCtx, done := context.WithTimeout(ctx, wait)
		defer done()
		conn, err := gonet.DialTCPWithBind(dialCtx, app, from, to, ipv4.ProtocolNumber)
		if err != nil {
			return err
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(wait))
		if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
			t.Fatalf("read before the stack's close: %v", err)
		}
		return nil
	}
	if err := dial(time.Second); err != nil {
		t.Fatal(err)
	}
	// The app's endpoint was the passive closer: its port is free once the final ACK arrives.
	time.Sleep(50 * time.Millisecond)
	// Shorter than the app's first SYN retransmission (1 s), so only an answer to the first SYN passes.
	if err := dial(500 * time.Millisecond); err != nil {
		t.Fatalf("connect reusing the port of a connection the stack closed first: %v", err)
	}
}
