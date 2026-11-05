package tuic

import (
	"context"
	"net"
	"syscall"
	"testing"

	M "github.com/sagernet/sing/common/metadata"
	"github.com/xtls/xray-core/common/buf"
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

// onePeer answers every read with a datagram from the same peer and keeps only the last write's address.
type onePeer struct {
	net.PacketConn
	from, to net.Addr
}

func (c *onePeer) ReadFrom(p []byte) (int, net.Addr, error)   { return 1200, c.from, nil }
func (c *onePeer) WriteTo(p []byte, to net.Addr) (int, error) { c.to = to; return len(p), nil }

// Each peer's address is parsed once; a datagram from another peer must get its own address, and
// each buffer its own destination, which later handlers rewrite.
func TestPacketReaderAndWriterTrackEachPeer(t *testing.T) {
	conn := &onePeer{}
	reader, writer := &packetReader{conn: conn}, &packetWriter{conn: conn, target: xnet.UDPDestination(xnet.ParseAddress("1.2.3.4"), 53)}
	var got []*xnet.Destination
	for _, addr := range []string{"1.2.3.4:53", "1.2.3.4:53", "[2001:db8::1]:443", "example.com:80", "1.2.3.4:53"} {
		// sing-quic reports an IP peer as a *net.UDPAddr, a domain as a Socksaddr.
		if from := M.ParseSocksaddr(addr); from.IsIP() {
			conn.from = from.UDPAddr()
		} else {
			conn.from = from
		}
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		if mb[0].UDP.NetAddr() != addr {
			t.Fatalf("a datagram from %s arrived from %s", addr, mb[0].UDP.NetAddr())
		}
		got = append(got, mb[0].UDP)
		if err := writer.WriteMultiBuffer(mb); err != nil {
			t.Fatal(err)
		}
		if conn.to.String() != addr {
			t.Fatalf("a datagram to %s went to %s", addr, conn.to)
		}
	}
	got[0].Port = 1
	if got[1].Port != 53 {
		t.Fatal("two buffers share one destination")
	}
}

func BenchmarkPacketReaderFromOnePeer(b *testing.B) {
	reader := &packetReader{conn: &onePeer{from: &net.UDPAddr{IP: net.IPv4(1, 2, 3, 4), Port: 443}}}
	b.ReportAllocs()
	for b.Loop() {
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			b.Fatal(err)
		}
		buf.ReleaseMulti(mb)
	}
}

func BenchmarkPacketWriterToOnePeer(b *testing.B) {
	writer := &packetWriter{conn: &onePeer{}, target: xnet.UDPDestination(xnet.ParseAddress("1.2.3.4"), 443)}
	b.ReportAllocs()
	for b.Loop() {
		packet := buf.New()
		packet.Extend(1200)
		if err := writer.WriteMultiBuffer(buf.MultiBuffer{packet}); err != nil {
			b.Fatal(err)
		}
	}
}
