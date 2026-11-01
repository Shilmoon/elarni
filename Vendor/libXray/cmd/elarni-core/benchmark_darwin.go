//go:build elarni_benchmark && darwin

package main

import (
	"golang.org/x/sys/unix"
	"net"
)

func benchmarkBind(fd uintptr, iface *net.Interface) error {
	address, err := unix.Getsockname(int(fd))
	if err != nil {
		return err
	}
	if _, ipv6 := address.(*unix.SockaddrInet6); ipv6 {
		return unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, iface.Index)
	}
	return unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, iface.Index)
}
