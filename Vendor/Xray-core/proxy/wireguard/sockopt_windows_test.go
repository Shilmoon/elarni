package wireguard

import "golang.org/x/sys/windows"

func getReceiveBuffer(fd uintptr) (int, error) {
	return windows.GetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_RCVBUF)
}
