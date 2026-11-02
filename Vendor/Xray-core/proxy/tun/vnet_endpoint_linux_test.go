//go:build linux && !android

package tun

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

// echoDispatcher plays the outbound: it sends back whatever the app sends.
type echoDispatcher struct{ routing.Dispatcher }

func (echoDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	return buf.Copy(link.Reader, link.Writer)
}

// tcpPackets records every TCP packet the TUN side writes, virtio_net_hdr included.
type tcpPackets struct {
	mu   sync.Mutex
	seen [][]byte
}

// relay copies packets between two SEQPACKET sockets, recording what from writes.
func relay(from, to int, record *tcpPackets) {
	packet := make([]byte, vnetHdrSize+vnetGSOMaxSize)
	for {
		n, err := unix.Read(from, packet)
		if err != nil || n == 0 {
			return
		}
		if record != nil && n >= vnetHdrSize+header.IPv4MinimumSize && packet[vnetHdrSize+9] == byte(header.TCPProtocolNumber) {
			record.mu.Lock()
			record.seen = append(record.seen, bytes.Clone(packet[:n]))
			record.mu.Unlock()
		}
		if _, err := unix.Write(to, packet[:n]); err != nil {
			return
		}
	}
}

func seqpacketPair(t *testing.T) (int, int) {
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	// A 64 KiB segment must fit the socket buffer whole, as it fits a TUN queue.
	for _, fd := range pair {
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, 4<<20)
	}
	return pair[0], pair[1]
}

// An app's TCP connection through a TUN opened with IFF_VNET_HDR: the app side is a
// second gVisor stack speaking virtio_net_hdr, as the kernel does. Segments go both
// ways at up to 64 KiB, and what the TUN side writes tells the kernel how to split
// and checksum them. No root needed: SOCK_SEQPACKET sockets stand in for the TUN.
func TestVnetTunCarriesTCPInOffloadedSegments(t *testing.T) {
	tunSide, relayTun := seqpacketPair(t)
	relayApp, appSide := seqpacketPair(t)
	defer unix.Close(tunSide)
	defer unix.Close(relayTun)
	defer unix.Close(relayApp)
	defer unix.Close(appSide)
	written := &tcpPackets{}
	go relay(relayTun, relayApp, written)
	go relay(relayApp, relayTun, nil)

	const mtu = 1500
	device := &LinuxTun{tunFd: tunSide, vnet: true, options: &Config{MTU: mtu}}
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: echoDispatcher{}}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		t.Fatal(err)
	}
	if err := network.Start(); err != nil {
		t.Fatal(err)
	}
	handler.stack, handler.tun = network, device
	defer handler.Close()

	app, err := newVnetEndpoint(appSide, mtu)
	if err != nil {
		t.Fatal(err)
	}
	appStack := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol},
	})
	defer func() { appStack.Close(); app.Close(); app.Wait() }()
	if err := appStack.CreateNIC(1, app); err != nil {
		t.Fatal(err)
	}
	appAddress := tcpip.AddrFrom4([4]byte{198, 18, 0, 2})
	if err := appStack.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: appAddress.WithPrefix()}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	appStack.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})

	conn, err := gonet.DialTCP(appStack, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{198, 18, 0, 3}), Port: 443}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	// Less than the sockets buffer: a SOCK_SEQPACKET write that finds no room drops the
	// packet (a TUN write does not), and gVisor's backed-off resends outlast the deadline.
	sent := make([]byte, 256<<10)
	rand.Read(sent)
	go conn.Write(sent)
	got := make([]byte, len(sent))
	if n, err := io.ReadFull(conn, got); err != nil {
		written.mu.Lock()
		defer written.mu.Unlock()
		t.Fatalf("echo stopped after %d bytes (%d TCP packets from the TUN side): %v", n, len(written.seen), err)
	}
	if !bytes.Equal(got, sent) {
		t.Fatal("echoed bytes differ")
	}

	written.mu.Lock()
	defer written.mu.Unlock()
	segmented := 0
	for i, packet := range written.seen {
		vnet, ip := packet[:vnetHdrSize], header.IPv4(packet[vnetHdrSize:])
		segment := header.TCP(ip.Payload())
		if vnet[0] == unix.VIRTIO_NET_HDR_F_NEEDS_CSUM {
			// What the kernel does with it: sum from csum_start, store at csum_offset.
			start, offset := int(binary.NativeEndian.Uint16(vnet[6:])), int(binary.NativeEndian.Uint16(vnet[8:]))
			if start != int(ip.HeaderLength()) || offset != header.TCPChecksumOffset {
				t.Fatalf("TCP packet %d: checksum from %d at +%d", i, start, offset)
			}
			binary.BigEndian.PutUint16(segment[offset:], ^checksum.Checksum(segment, 0))
		} else if vnet[1] != unix.VIRTIO_NET_HDR_GSO_NONE {
			t.Fatalf("TCP packet %d: segmented with no checksum to complete", i)
		}
		if !segment.IsChecksumValid(ip.SourceAddress(), ip.DestinationAddress(), checksum.Checksum(segment.Payload(), 0), uint16(len(segment.Payload()))) {
			t.Fatalf("TCP packet %d (%x): checksum invalid", i, vnet)
		}
		if vnet[1] == unix.VIRTIO_NET_HDR_GSO_TCPV4 {
			segmented++
			if mss := binary.NativeEndian.Uint16(vnet[4:]); mss == 0 || mss > mtu-40 || len(ip) <= mtu {
				t.Fatalf("TCP packet %d: %d bytes split at %d", i, len(ip), mss)
			}
		} else if len(ip) > mtu {
			t.Fatalf("TCP packet %d: %d bytes with gso_type %d", i, len(ip), vnet[1])
		}
	}
	if segmented == 0 {
		t.Fatalf("none of %d TCP packets was larger than the MTU", len(written.seen))
	}
}

func TestVnetEndpointCloseReleasesItsReader(t *testing.T) {
	before := eventfds(t)
	for range 20 {
		tunSide, peer := seqpacketPair(t)
		device := &LinuxTun{tunFd: tunSide, vnet: true, options: &Config{MTU: 1500}}
		handler := &Handler{ctx: context.Background(), config: &Config{}}
		network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
		if err != nil {
			t.Fatal(err)
		}
		if err := network.Start(); err != nil {
			t.Fatal(err)
		}
		handler.stack, handler.tun = network, device
		done := make(chan error)
		go func() { done <- handler.Close() }()
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("Close did not stop the reader")
		}
		unix.Close(peer)
	}
	if after := eventfds(t); after > before {
		t.Fatalf("%d eventfds stayed open after 20 TUN start and close cycles", after-before)
	}
}
