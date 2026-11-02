package tuic

import (
	"context"
	"net"
	"syscall"
	"testing"

	M "github.com/sagernet/sing/common/metadata"
	xnet "github.com/xtls/xray-core/common/net"
)

// Queued datagrams wait for a slow reader; each must hold only its own bytes.
func TestPacketReaderSizesBuffersToTheDatagram(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sender, err := net.Dial("udp", conn.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	if _, err := sender.Write(make([]byte, 100)); err != nil {
		t.Fatal(err)
	}
	reader := &packetReader{conn: conn}
	mb, err := reader.ReadMultiBuffer()
	if err != nil {
		t.Fatal(err)
	}
	defer mb[0].Release()
	if mb[0].Len() != 100 || mb[0].Cap() > 2048 {
		t.Fatalf("a 100-byte datagram holds a %d-byte buffer", mb[0].Cap())
	}
}

func receiveBuffer(t *testing.T, conn syscall.Conn) int {
	t.Helper()
	raw, err := conn.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	size := 0
	raw.Control(func(fd uintptr) { size, err = getReceiveBuffer(fd) })
	if err != nil {
		t.Fatal(err)
	}
	return size
}

// The wrapper hides the socket from quic-go, which therefore never enlarged its
// receive buffer: hundreds of datagrams per transfer were dropped on macOS.
func TestUpstreamSocketsGetLargeBuffers(t *testing.T) {
	peer, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	fresh, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defaultSize := receiveBuffer(t, fresh)
	fresh.Close()
	dialer := &socketDialer{sockets: make(map[*ownedSocket]struct{})}
	conn, err := dialer.DialContext(context.Background(), "udp", M.ParseSocksaddr(peer.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	udp := conn.(*ownedSocket).Conn.(*xnet.PacketConnWrapper).PacketConn.(*net.UDPConn)
	if size := receiveBuffer(t, udp); size <= defaultSize {
		t.Fatalf("receive buffer %d, default %d", size, defaultSize)
	}
}
