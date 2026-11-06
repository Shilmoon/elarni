//go:build linux && !android

package tun

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"golang.org/x/sys/unix"
)

// Holds the session open like an outbound whose reply is still in flight.
type lateReplyDispatcher struct {
	routing.Dispatcher
	link    chan *transport.Link
	release chan struct{}
}

func (d *lateReplyDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	d.link <- link
	<-d.release
	return nil
}

// receive returns one packet from fd, or nil if none arrives within wait.
func receive(fd int, wait time.Duration) []byte {
	fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	if n, _ := unix.Poll(fds, int(wait/time.Millisecond)); n <= 0 {
		return nil
	}
	data := make([]byte, 65536)
	n, err := unix.Read(fd, data)
	if err != nil {
		return nil
	}
	return data[:n]
}

func sendReply(link *transport.Link) {
	b := buf.New()
	b.WriteString("reply")
	_ = link.Writer.WriteMultiBuffer(buf.MultiBuffer{b}) // the error is not the point; where the bytes go is
}

// fdbased.New does not own its descriptor: it must stay open until the endpoint
// stops being used. Handler.Close closes the TUN descriptor but leaves the gVisor
// NIC attached, so a reply that arrives after Close must not reach whatever file
// the kernel later gives the same descriptor number.
// No root needed: the real LinuxTun runs over a SOCK_SEQPACKET socketpair.
func TestHandlerCloseStopsWritesToReusedTunDescriptor(t *testing.T) {
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	tunSide, peer := pair[0], pair[1]
	defer unix.Close(peer)
	device := &LinuxTun{tunFd: tunSide, options: &Config{MTU: 1500}} // ownsTun=false: Close touches no netlink state
	dispatcher := &lateReplyDispatcher{link: make(chan *transport.Link, 1), release: make(chan struct{})}
	defer close(dispatcher.release)
	handler := &Handler{ctx: context.Background(), config: &Config{}, dispatcher: dispatcher}
	network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
	if err != nil {
		t.Fatal(err)
	}
	if err := network.Start(); err != nil {
		t.Fatal(err)
	}
	handler.stack, handler.tun = network, device

	// Open the session from this goroutine: a packet read through the descriptor has no
	// happens-before edge to Start's handler setup, so the race detector would flag gVisor.
	network.(*stackGVisor).udpHandler.HandlePacket(net.UDPDestination(net.ParseAddress("198.18.0.2"), 40000),
		net.UDPDestination(net.ParseAddress("198.18.0.3"), 50000), buf.FromBytes([]byte{1}))
	var link *transport.Link
	select {
	case link = <-dispatcher.link:
	case <-time.After(2 * time.Second):
		t.Fatal("UDP session did not reach dispatcher")
	}

	// Harness check: before Close a reply reaches the TUN peer.
	sendReply(link)
	if got := receive(peer, 2*time.Second); !bytes.HasSuffix(got, []byte("reply")) {
		t.Fatalf("reply before Close did not reach the TUN descriptor (got %d bytes); harness broken", len(got))
	}

	if err := handler.Close(); err != nil {
		t.Fatal(err)
	}
	// Reuse the freed number the way the kernel does (lowest free), else force it.
	pair, err = unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	reusedPeer := pair[1]
	switch tunSide {
	case pair[0]:
	case pair[1]:
		reusedPeer = pair[0]
	default:
		if err := unix.Dup3(pair[0], tunSide, unix.O_CLOEXEC); err != nil {
			t.Fatal(err)
		}
		unix.Close(pair[0])
	}
	defer unix.Close(tunSide)
	defer unix.Close(reusedPeer)

	sendReply(link) // the outbound's late reply
	if got := receive(reusedPeer, 300*time.Millisecond); got != nil {
		t.Fatalf("a %d-byte packet (UDP reply: %v) was written to a reused descriptor after Handler.Close returned",
			len(got), bytes.HasSuffix(got, []byte("reply")))
	}
}
