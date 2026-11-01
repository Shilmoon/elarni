package internet

import (
	"bytes"
	"context"
	"net"
	"testing"
	"time"
)

// Darwin's default send buffer rejects datagrams over 9216 bytes.
func TestListenPacketSendsLargeDatagrams(t *testing.T) {
	conn, err := (&DefaultListener{}).ListenPacket(context.Background(), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	payload := bytes.Repeat([]byte{0x6b}, 32768)
	if _, err := conn.WriteTo(payload, conn.LocalAddr()); err != nil {
		t.Fatalf("large datagram rejected: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	received := make([]byte, 65535)
	n, _, err := conn.ReadFrom(received)
	if err != nil || !bytes.Equal(received[:n], payload) {
		t.Fatalf("received %d bytes: %v", n, err)
	}
}
