//go:build darwin && !ios

package net

import (
	"encoding/binary"
	"net/netip"

	"golang.org/x/sys/unix"

	"github.com/xtls/xray-core/common/errors"
)

// EstablishedTCPConnections lists every program's established TCP connections from the socket
// table, which the App Sandbox lets the app and its extension read.
func EstablishedTCPConnections() ([]TCPConnection, error) {
	table, err := unix.SysctlRaw("net.inet.tcp.pcblist_n")
	if err != nil {
		return nil, errors.New("failed to read socket table").Base(err)
	}
	return darwinTCPConnections(table)
}

// darwinTCPConnections reads net.inet.tcp.pcblist_n, as darwinSocketPID does. Each connection's
// records are xinpcb_n, xsocket_n, two xsockbuf_n, xsockstat_n, then xtcpcb_n with its state
// (bsd/netinet/in_pcblist.c, tcp_pcblist_n).
func darwinTCPConnections(table []byte) ([]TCPConnection, error) {
	invalid := errors.New("invalid Darwin socket table")
	if len(table) < 24 {
		return nil, invalid
	}
	headerSize := int(binary.NativeEndian.Uint32(table[:4]))
	if headerSize < 24 || (headerSize+7)&^7 > len(table) {
		return nil, invalid
	}
	generation := binary.NativeEndian.Uint64(table[8:16])
	var pcb, socket []byte
	var connections []TCPConnection
	complete := headerSize == len(table)
	for offset := (headerSize + 7) &^ 7; offset < len(table); {
		if len(table)-offset < 8 {
			return nil, invalid
		}
		size := int(binary.NativeEndian.Uint32(table[offset:]))
		aligned := (size + 7) &^ 7
		if size < 8 || aligned > len(table)-offset {
			return nil, invalid
		}
		if size == 24 && offset+size == len(table) { // final xinpgen
			complete = true
			break
		}
		record := table[offset : offset+size]
		offset += aligned
		switch binary.NativeEndian.Uint32(record[4:8]) {
		case 0x010: // XSO_INPCB / xinpcb_n
			if size < 104 {
				return nil, invalid
			}
			pcb, socket = record, nil
		case 0x001: // XSO_SOCKET / xsocket_n
			if size < 76 {
				return nil, invalid
			}
			socket = record
		case 0x020: // XSO_TCPCB / xtcpcb_n: t_state follows t_segq, t_dupacks and four timers
			if size < 40 {
				return nil, invalid
			}
			entry, owner := pcb, socket
			pcb, socket = nil, nil
			if entry == nil || owner == nil || int32(binary.NativeEndian.Uint32(record[36:40])) != 4 { // TCPS_ESTABLISHED
				continue
			}
			if binary.NativeEndian.Uint64(entry[8:16]) != binary.NativeEndian.Uint64(owner[28:36]) ||
				binary.NativeEndian.Uint64(entry[28:36]) > generation ||
				binary.NativeEndian.Uint32(owner[36:40]) != unix.IPPROTO_TCP {
				continue
			}
			var local, remote netip.Addr
			switch {
			case entry[44]&1 != 0: // INP_IPV4
				local, remote = netip.AddrFrom4([4]byte(entry[76:80])), netip.AddrFrom4([4]byte(entry[60:64]))
			case entry[44]&2 != 0: // INP_IPV6
				local, remote = netip.AddrFrom16([16]byte(entry[64:80])), netip.AddrFrom16([16]byte(entry[48:64]))
			default:
				continue
			}
			pid := int32(binary.NativeEndian.Uint32(owner[72:76]))
			if pid == 0 {
				pid = int32(binary.NativeEndian.Uint32(owner[68:72]))
			}
			if pid <= 0 {
				continue
			}
			connections = append(connections, TCPConnection{
				Local:  netip.AddrPortFrom(local, binary.BigEndian.Uint16(entry[18:20])),
				Remote: netip.AddrPortFrom(remote, binary.BigEndian.Uint16(entry[16:18])),
				PID:    int(pid),
			})
		}
	}
	if !complete {
		return nil, invalid
	}
	return connections, nil
}

// ResetTCPConnection: macOS lets no program reset another's connection.
func ResetTCPConnection(TCPConnection) error { return ErrResetUnsupported }
