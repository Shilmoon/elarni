//go:build elarni_benchmark && windows

package main

import (
	"encoding/binary"
	"golang.org/x/sys/windows"
	"net"
	"unsafe"
)

// SO_PROTOCOL_INFOW; x/sys/windows does not export it.
const soProtocolInfoW = 0x2005

func benchmarkBind(fd uintptr, iface *net.Interface) error {
	// Control runs before bind, where getsockname fails with WSAEINVAL; the
	// protocol info reports the socket family on an unbound socket.
	var info windows.WSAProtocolInfo
	size := int32(unsafe.Sizeof(info))
	if err := windows.Getsockopt(windows.Handle(fd), windows.SOL_SOCKET, soProtocolInfoW, (*byte)(unsafe.Pointer(&info)), &size); err != nil {
		return err
	}
	if info.AddressFamily == windows.AF_INET6 {
		if err := windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, 31, iface.Index); err != nil {
			return err
		}
		// A dual-stack socket sends IPv4 by the IPv4 option.
		if only, err := windows.GetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, windows.IPV6_V6ONLY); err != nil || only != 0 {
			return err
		}
	}
	// IP_UNICAST_IF accepts unknown indexes; the socket would follow the default route.
	row := windows.MibIfRow2{InterfaceIndex: uint32(iface.Index)}
	if err := windows.GetIfEntry2Ex(windows.MibIfEntryNormalWithoutStatistics, &row); err != nil {
		return err
	}
	var index [4]byte
	binary.BigEndian.PutUint32(index[:], uint32(iface.Index))
	return windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31, int(binary.NativeEndian.Uint32(index[:])))
}
