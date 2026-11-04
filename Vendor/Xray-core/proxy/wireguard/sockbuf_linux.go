package wireguard

import (
	"net"

	"golang.org/x/sys/unix"
)

// forceBuffers passes Linux's net.core limits when the core may (CAP_NET_ADMIN), as wireguard-go's bind does.
func forceBuffers(udp *net.UDPConn) {
	raw, err := udp.SyscallConn()
	if err != nil {
		return
	}
	raw.Control(func(fd uintptr) {
		_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_RCVBUFFORCE, socketBuffer)
		_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_SNDBUFFORCE, socketBuffer)
	})
}
