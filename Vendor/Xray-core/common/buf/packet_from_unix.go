//go:build unix

package buf

import (
	"net"
	"strconv"
	"sync"
	"syscall"
)

const pooledUDPReads = true

var udpScratch = sync.Pool{New: func() any { scratch := make([]byte, UDPSize); return &scratch }}

func readUDPFrom(conn *net.UDPConn) (*Buffer, net.Addr, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return nil, nil, err
	}
	var b *Buffer
	var from syscall.Sockaddr
	var readErr error
	err = raw.Read(func(fd uintptr) bool {
		scratch := udpScratch.Get().(*[]byte)
		defer udpScratch.Put(scratch)
		var n int
		for {
			n, from, readErr = syscall.Recvfrom(int(fd), *scratch, 0)
			if readErr != syscall.EINTR {
				break
			}
		}
		if readErr == syscall.EAGAIN {
			return false // wait until readable
		}
		if readErr == nil {
			b = NewWithSize(int32(n))
			b.Write((*scratch)[:n])
		}
		return true
	})
	if err == nil {
		err = readErr
	}
	if err != nil {
		return nil, nil, err
	}
	// As net.UDPConn.ReadFrom converts the address.
	switch sa := from.(type) {
	case *syscall.SockaddrInet4:
		return b, &net.UDPAddr{IP: sa.Addr[0:], Port: sa.Port}, nil
	case *syscall.SockaddrInet6:
		zone := ""
		if sa.ZoneId != 0 {
			zone = strconv.Itoa(int(sa.ZoneId))
			if ifi, err := net.InterfaceByIndex(int(sa.ZoneId)); err == nil {
				zone = ifi.Name
			}
		}
		return b, &net.UDPAddr{IP: sa.Addr[0:], Port: sa.Port, Zone: zone}, nil
	}
	return b, nil, nil
}
