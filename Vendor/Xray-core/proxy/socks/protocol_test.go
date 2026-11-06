package socks_test

import (
	stdnet "net"
	"testing"

	appstats "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/proxy/socks"
	"github.com/xtls/xray-core/transport/internet/stat"
)

// The SOCKS outbound's UDP replies arrive on the dialed socket, counted when outbound stats are on.
func TestUDPReaderDecodesRepliesFromDialedSocket(t *testing.T) {
	for _, counted := range []bool{false, true} {
		local, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer local.Close()
		server, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer server.Close()
		var conn stat.Connection = &net.PacketConnWrapper{PacketConn: local, Dest: server.LocalAddr()}
		var counter appstats.Counter
		if counted {
			conn = &stat.CounterConnection{Connection: conn, ReadCounter: &counter}
		}
		from := net.UDPDestination(net.ParseAddress("192.0.2.7"), 3478)
		reply, err := socks.EncodeUDPPacket(&protocol.RequestHeader{Address: from.Address, Port: from.Port}, []byte("reply"))
		if err != nil {
			t.Fatal(err)
		}
		server.WriteTo(reply.Bytes(), local.LocalAddr())
		size := reply.Len()
		reply.Release()
		mb, err := (&socks.UDPReader{Reader: conn}).ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		if mb.String() != "reply" || mb[0].UDP == nil || *mb[0].UDP != from {
			t.Fatalf("read %q from %v, want %q from %v", mb.String(), mb[0].UDP, "reply", from)
		}
		buf.ReleaseMulti(mb)
		if counted && counter.Value() != int64(size) {
			t.Fatalf("counted %d bytes, want %d", counter.Value(), size)
		}
	}
}
