//go:build !linux

package wireguard

import "net"

func forceBuffers(*net.UDPConn) {}
