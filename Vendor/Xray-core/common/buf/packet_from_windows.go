package buf

import (
	"encoding/binary"
	"net"
	"syscall"
	"unsafe"
)

const pooledUDPReads = true

const fionread = 0x4004667f // _IOR('f', 127, u_long) in winsock2.h

// readUDPFrom reads into a pooled buffer only once a datagram is known to be queued: Go's
// sockets are overlapped, so a recvfrom with nothing queued would block the thread and Close.
// *state keeps the queued bytes FIONREAD reported that are still unread, so a backlog costs
// one ioctl rather than one per datagram.
func readUDPFrom(conn *net.UDPConn, state *[]byte) (*Buffer, net.Addr, error) {
	if len(*state) != 8 {
		*state = make([]byte, 8)
	}
	queued := binary.LittleEndian.Uint64(*state)
	binary.LittleEndian.PutUint64(*state, 0)
	if queued == 0 {
		var err error
		if queued, err = waitQueued(conn); err != nil {
			return nil, nil, err
		}
	}
	scratch := udpScratch.Get().(*[]byte)
	defer udpScratch.Put(scratch)
	b, addr, err := readPacketCopy(conn, *scratch)
	if err == nil && b.Len() > 0 { // a lone empty datagram reads as 1 queued byte
		binary.LittleEndian.PutUint64(*state, queued-min(queued, uint64(b.Len())))
	}
	return b, addr, err
}

// waitQueued returns the queued bytes FIONREAD reports, or 0 once RawRead's zero-byte peek
// saw a datagram, maybe an empty one, arrive.
func waitQueued(conn *net.UDPConn) (uint64, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var queued uint32
	checked := false
	err = raw.Read(func(fd uintptr) bool {
		if checked {
			return true // the peek completed
		}
		checked = true
		var size uint32
		err := syscall.WSAIoctl(syscall.Handle(fd), fionread, nil, 0, (*byte)(unsafe.Pointer(&queued)), 4, &size, nil, 0)
		return err != nil || queued > 0 // on an error ReadFrom reports it
	})
	return uint64(queued), err
}
