package hysteria

import (
	"testing"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
)

// replies returns the last message written on every Read, as a server answering one peer does.
type replies struct{ message []byte }

func (r *replies) Read(p []byte) (int, error) { return copy(p, r.message), nil }
func (r *replies) Write(p []byte) (int, error) {
	r.message = append(r.message[:0], p...)
	return len(p), nil
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func message(addr string) []byte {
	b := make([]byte, 1500)
	return b[:(&UDPMessage{FragCount: 1, Addr: addr, Data: []byte{1}}).Serialize(b)]
}

// Each peer's address is parsed once; a message from another peer must get its own address, and
// each buffer its own destination, which later handlers rewrite.
func TestUDPReaderGivesEachMessageItsPeer(t *testing.T) {
	r := &replies{}
	reader := &UDPReader{reader: r, df: &Defragger{}}
	var got []*net.Destination
	for _, addr := range []string{"1.2.3.4:53", "1.2.3.4:53", "[2001:db8::1]:443", "example.com:80"} {
		r.message = message(addr)
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		if mb[0].UDP.NetAddr() != addr {
			t.Fatalf("a message from %s arrived from %s", addr, mb[0].UDP.NetAddr())
		}
		got = append(got, mb[0].UDP)
		buf.ReleaseMulti(mb)
	}
	got[0].Port = 1
	if got[1].Port != 53 {
		t.Fatal("two buffers share one destination")
	}
}

func TestUDPWriterAddressesEachPacketToItsPeer(t *testing.T) {
	r := &replies{}
	writer := &UDPWriter{writer: r, addr: "1.2.3.4:53"}
	reader := &UDPReader{reader: r, df: &Defragger{}}
	for _, addr := range []string{"1.2.3.4:53", "[2001:db8::1]:443", "example.com:80", "example.com:80"} {
		destination, _ := net.ParseDestination("udp:" + addr)
		packet := buf.New()
		packet.WriteByte(1)
		packet.UDP = &destination
		if err := writer.WriteMultiBuffer(buf.MultiBuffer{packet}); err != nil {
			t.Fatal(err)
		}
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		if mb[0].UDP.NetAddr() != addr {
			t.Fatalf("a packet to %s went to %s", addr, mb[0].UDP.NetAddr())
		}
		buf.ReleaseMulti(mb)
	}
}

func BenchmarkUDPReaderFromOnePeer(b *testing.B) {
	message := make([]byte, 1500)
	n := (&UDPMessage{FragCount: 1, Addr: "1.2.3.4:443", Data: make([]byte, 1200)}).Serialize(message)
	reader := &UDPReader{reader: &replies{message: message[:n]}, df: &Defragger{}}
	b.ReportAllocs()
	for b.Loop() {
		mb, err := reader.ReadMultiBuffer()
		if err != nil {
			b.Fatal(err)
		}
		buf.ReleaseMulti(mb)
	}
}

func BenchmarkUDPWriterToOnePeer(b *testing.B) {
	writer := &UDPWriter{writer: discard{}, addr: "1.2.3.4:443"}
	destination := net.UDPDestination(net.ParseAddress("1.2.3.4"), 443)
	b.ReportAllocs()
	for b.Loop() {
		packet := buf.New()
		packet.Extend(1200)
		packet.UDP = &destination
		if err := writer.WriteMultiBuffer(buf.MultiBuffer{packet}); err != nil {
			b.Fatal(err)
		}
	}
}
