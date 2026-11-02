package buf

import "net"

// ReadPacketFrom reads one datagram whole into a buffer of its size. A UDP socket on
// Unix waits without a buffer and borrows a pooled UDPSize one once a datagram is
// ready; other connections read into *scratch, allocated on first use.
func ReadPacketFrom(conn net.PacketConn, scratch *[]byte) (*Buffer, net.Addr, error) {
	if udp, ok := conn.(*net.UDPConn); ok && pooledUDPReads {
		return readUDPFrom(udp)
	}
	if *scratch == nil {
		*scratch = make([]byte, UDPSize)
	}
	n, addr, err := conn.ReadFrom(*scratch)
	if err != nil {
		return nil, nil, err
	}
	b := NewWithSize(int32(n))
	b.Write((*scratch)[:n])
	return b, addr, nil
}
