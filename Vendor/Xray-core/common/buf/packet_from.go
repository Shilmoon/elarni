package buf

import (
	"net"
	"sync"
)

var udpScratch = sync.Pool{New: func() any { scratch := make([]byte, UDPSize); return &scratch }}

// ReadPacketFrom reads one datagram whole into a buffer of its size. A UDP socket on
// Unix and Windows waits without a buffer and borrows a pooled UDPSize one once a
// datagram is ready; other connections read into *scratch, allocated on first use.
// *scratch belongs to one reader: on Windows it counts a UDP socket's queued bytes.
func ReadPacketFrom(conn net.PacketConn, scratch *[]byte) (*Buffer, net.Addr, error) {
	if udp, ok := conn.(*net.UDPConn); ok && pooledUDPReads {
		return readUDPFrom(udp, scratch)
	}
	if *scratch == nil {
		*scratch = make([]byte, UDPSize)
	}
	return readPacketCopy(conn, *scratch)
}

func readPacketCopy(conn net.PacketConn, scratch []byte) (*Buffer, net.Addr, error) {
	n, addr, err := conn.ReadFrom(scratch)
	if err != nil {
		return nil, nil, err
	}
	b := NewWithSize(int32(n))
	b.Write(scratch[:n])
	return b, addr, nil
}
