//go:build elarni_benchmark && linux

package main

import (
	"golang.org/x/sys/unix"
	"net"
)

func benchmarkBind(fd uintptr, iface *net.Interface) error {
	return unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, iface.Name)
}
