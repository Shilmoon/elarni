package socks_test

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/proxy/socks"
)

func TestTempUDPConnClosesBeforeAndAfterTimeoutSetup(t *testing.T) {
	for _, timeout := range []time.Duration{-1, 0, time.Minute} {
		t.Run(timeout.String(), func(t *testing.T) {
			udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer udp.Close()
			left, right := net.Pipe()
			defer left.Close()
			defer right.Close()
			conn := socks.NewTempUDPConn(udp, left, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
			defer func() {
				if value := recover(); value != nil {
					t.Fatalf("closing UDP association panicked: %v", value)
				}
			}()
			if timeout >= 0 {
				conn.SetTimeout(timeout)
			}
			conn.Close()
			if _, _, err := udp.ReadFrom(make([]byte, 1)); !errors.Is(err, net.ErrClosed) {
				t.Fatalf("UDP socket not closed: %v", err)
			}
			if _, err := right.Read(make([]byte, 1)); err == nil {
				t.Fatal("associated TCP stream not closed")
			}
		})
	}
}

// The association's reader takes datagrams only from its client, learning the client's port from
// the first one when the UDP ASSOCIATE request left it open.
func TestTempUDPConnReadsOnlyItsClient(t *testing.T) {
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	client, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	stranger, err := net.ListenPacket("udp4", "127.0.0.2:0")
	if err != nil {
		t.Skip("no second loopback address:", err)
	}
	defer stranger.Close()
	left, right := net.Pipe()
	defer right.Close()
	conn := socks.NewTempUDPConn(udp, left, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	conn.SetTimeout(time.Minute)
	defer conn.Close()
	reader := buf.NewPacketReader(conn)
	stranger.WriteTo([]byte("stranger"), udp.LocalAddr())
	client.WriteTo([]byte("first"), udp.LocalAddr())
	sibling, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sibling.Close()
	sibling.WriteTo([]byte("other port"), udp.LocalAddr())
	client.WriteTo([]byte("second"), udp.LocalAddr())
	for _, want := range []string{"first", "second"} {
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		if got := mb.String(); got != want {
			t.Fatalf("read %q, want %q", got, want)
		}
		buf.ReleaseMulti(mb)
	}
	if got := conn.RemoteAddr().String(); got != client.LocalAddr().String() {
		t.Fatalf("learned client %s, want %s", got, client.LocalAddr())
	}
}

func benchmarkAssociation(b *testing.B) (*socks.TempUDPConn, net.PacketConn) {
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		b.Fatal(err)
	}
	client, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		b.Fatal(err)
	}
	left, right := net.Pipe()
	conn := socks.NewTempUDPConn(udp, left, client.LocalAddr().(*net.UDPAddr))
	conn.SetTimeout(time.Hour)
	b.Cleanup(func() { conn.Close(); client.Close(); right.Close() })
	return conn, client
}

// Each association's reader, up to its first datagram.
func BenchmarkTempUDPConnAssociationReader(b *testing.B) {
	conn, client := benchmarkAssociation(b)
	payload := make([]byte, 1200)
	b.ReportAllocs()
	for range b.N {
		client.WriteTo(payload, conn.LocalAddr())
		mb, err := buf.NewPacketReader(conn).ReadMultiBuffer()
		if err != nil {
			b.Fatal(err)
		}
		buf.ReleaseMulti(mb)
	}
}

// Datagrams through one association's reader.
func BenchmarkTempUDPConnDatagram(b *testing.B) {
	conn, client := benchmarkAssociation(b)
	reader := buf.NewPacketReader(conn)
	payload := make([]byte, 1200)
	b.SetBytes(1200)
	b.ReportAllocs()
	for range b.N {
		client.WriteTo(payload, conn.LocalAddr())
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			b.Fatal(err)
		}
		buf.ReleaseMulti(mb)
	}
}
