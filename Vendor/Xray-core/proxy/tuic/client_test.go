package tuic

import (
	"net"
	"testing"
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
