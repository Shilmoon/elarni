//go:build unix

package wireguard

import "syscall"

func getReceiveBuffer(fd uintptr) (int, error) {
	return syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
}
