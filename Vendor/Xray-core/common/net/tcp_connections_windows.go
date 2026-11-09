//go:build windows

package net

import (
	"encoding/binary"
	"net/netip"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	tcpStateEstablished = 5  // MIB_TCP_STATE_ESTAB
	tcpStateDeleteTCB   = 12 // MIB_TCP_STATE_DELETE_TCB
)

var procSetTcpEntry = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("SetTcpEntry")

// EstablishedTCPConnections lists every program's established TCP connections.
func EstablishedTCPConnections() ([]TCPConnection, error) {
	once.Do(func() {
		initErr = initWin32API()
	})
	if initErr != nil {
		return nil, initErr
	}
	var connections []TCPConnection
	for i, table := range transportTables[:2] { // tcp4, tcp6
		buf, err := table.get()
		if err != nil {
			return nil, err
		}
		connections = append(connections, windowsTCPConnections(buf, i == 1)...)
	}
	return connections, nil
}

// windowsTCPConnections reads MIB_TCPTABLE_OWNER_PID or MIB_TCP6TABLE_OWNER_PID. A port sits in
// network order in the low word of its DWORD.
func windowsTCPConnections(table []byte, ipv6 bool) []TCPConnection {
	if len(table) < 4 {
		return nil
	}
	size := 24
	if ipv6 {
		size = 56
	}
	rows := int(binary.LittleEndian.Uint32(table))
	var connections []TCPConnection
	for i := 0; i < rows && 4+(i+1)*size <= len(table); i++ {
		row := table[4+i*size : 4+(i+1)*size]
		port := func(at int) uint16 { return binary.BigEndian.Uint16(row[at : at+2]) }
		var connection TCPConnection
		if ipv6 {
			if binary.LittleEndian.Uint32(row[48:]) != tcpStateEstablished {
				continue
			}
			connection.Local = netip.AddrPortFrom(netip.AddrFrom16([16]byte(row[0:16])), port(20))
			connection.Remote = netip.AddrPortFrom(netip.AddrFrom16([16]byte(row[24:40])), port(44))
			connection.PID = int(binary.LittleEndian.Uint32(row[52:]))
		} else {
			if binary.LittleEndian.Uint32(row) != tcpStateEstablished {
				continue
			}
			connection.Local = netip.AddrPortFrom(netip.AddrFrom4([4]byte(row[4:8])), port(8))
			connection.Remote = netip.AddrPortFrom(netip.AddrFrom4([4]byte(row[12:16])), port(16))
			connection.PID = int(binary.LittleEndian.Uint32(row[20:]))
		}
		connections = append(connections, connection)
	}
	return connections
}

// ResetTCPConnection resets an IPv4 connection; it needs an administrator. Windows has no call
// that resets an IPv6 connection.
func ResetTCPConnection(connection TCPConnection) error {
	local, remote := connection.Local.Addr().Unmap(), connection.Remote.Addr().Unmap()
	if !local.Is4() || !remote.Is4() {
		return ErrResetUnsupported
	}
	address := func(addr netip.Addr) uint32 {
		ip := addr.As4()
		return binary.LittleEndian.Uint32(ip[:]) // the bytes in network order
	}
	port := func(value uint16) uint32 {
		var raw [4]byte
		binary.BigEndian.PutUint16(raw[:2], value)
		return binary.LittleEndian.Uint32(raw[:])
	}
	// MIB_TCPROW
	row := [5]uint32{tcpStateDeleteTCB, address(local), port(connection.Local.Port()), address(remote), port(connection.Remote.Port())}
	if r, _, _ := procSetTcpEntry.Call(uintptr(unsafe.Pointer(&row))); r != 0 {
		return syscall.Errno(r)
	}
	return nil
}
