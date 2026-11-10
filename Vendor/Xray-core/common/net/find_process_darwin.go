//go:build darwin && !ios

package net

import (
	"bytes"
	"encoding/binary"
	"net"
	"net/netip"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/xtls/xray-core/common/errors"
)

func FindProcess(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (PID int, Name string, AbsolutePath string, err error) {
	isLocal, err := IsLocal(net.ParseIP(srcIP))
	if err != nil {
		return 0, "", "", errors.New("failed to determine if address is local: ", err)
	}
	if !isLocal {
		return 0, "", "", ErrNotLocal
	}
	if network != "tcp" && network != "udp" {
		panic("Unsupported network type for process lookup.")
	}
	srcAddr, err := netip.ParseAddr(srcIP)
	if err != nil {
		return 0, "", "", errors.New("invalid source IP address: ", srcIP)
	}
	var dstAddr netip.Addr
	if destIP != "" && destPort != 0 {
		dstAddr, err = netip.ParseAddr(destIP)
		if err != nil {
			return 0, "", "", errors.New("invalid destination IP address: ", destIP)
		}
		dstAddr = dstAddr.Unmap()
	}
	// App Sandbox denies proc_pidfdinfo for foreign processes. The socket tables
	// expose ownership without a per-process scan (and its sandbox denial storm).
	table, err := darwinSocketTables[network].get()
	if err != nil {
		return 0, "", "", errors.New("failed to read socket table").Base(err)
	}
	pid, err := darwinSocketPID(table, network, srcAddr.Unmap(), srcPort, dstAddr, destPort)
	if err != nil {
		return 0, "", "", err
	}
	if pid <= 0 {
		return 0, "", "", errors.New("process not found for ", network, " connection")
	}
	absPath, err := darwinProcessPath(pid)
	if err != nil {
		return 0, "", "", errors.New("could not get process path for PID ", pid, ": ", err)
	}
	absPath = filepath.ToSlash(absPath)
	return int(pid), filepath.Base(absPath), absPath, nil
}

// darwinSocketTables shares socket-table reads between concurrent lookups (Elarni): a read
// copies every socket of the host, about 1 ms with a browser's, and a burst of new
// connections made one each. The tables are only read, so lookups share one copy.
var darwinSocketTables = map[string]*processTable{
	"tcp": {fetch: func(uint32) ([]byte, error) { return unix.SysctlRaw("net.inet.tcp.pcblist_n") }},
	"udp": {fetch: func(uint32) ([]byte, error) { return unix.SysctlRaw("net.inet.udp.pcblist_n") }},
}

// pcblist_n uses length/kind records aligned to 8 bytes, with pack(4) fields.
// Layout: Apple's bsd/{netinet/in_pcb.h,sys/socketvar.h}; export/grouping:
// https://github.com/apple/darwin-xnu/blob/main/bsd/netinet/in_pcblist.c
// These are private ABI records: validate lengths and the PCB handle before use.
func darwinSocketPID(table []byte, network string, src netip.Addr, srcPort uint16, dst netip.Addr, dstPort uint16) (int32, error) {
	invalid := errors.New("invalid Darwin socket table")
	if len(table) < 24 {
		return 0, invalid
	}
	headerSize := int(binary.NativeEndian.Uint32(table[:4]))
	if headerSize < 24 || (headerSize+7)&^7 > len(table) {
		return 0, invalid
	}
	generation := binary.NativeEndian.Uint64(table[8:16])
	protocol := uint32(unix.IPPROTO_TCP)
	if network == "udp" {
		protocol = unix.IPPROTO_UDP
	}
	var pcb, socket []byte
	var found int32
	complete := headerSize == len(table) // an empty kernel table has no footer
	for offset := (headerSize + 7) &^ 7; offset < len(table); {
		if len(table)-offset < 8 {
			return 0, invalid
		}
		size := int(binary.NativeEndian.Uint32(table[offset:]))
		aligned := (size + 7) &^ 7
		if size < 8 || aligned > len(table)-offset {
			return 0, invalid
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
				return 0, invalid
			}
			pcb = record
		case 0x001: // XSO_SOCKET / xsocket_n
			if size < 76 {
				return 0, invalid
			}
			socket = record
		default:
			continue
		}
		if pcb == nil || socket == nil {
			continue
		}
		entry, owner := pcb, socket
		pcb, socket = nil, nil
		if binary.NativeEndian.Uint64(entry[8:16]) != binary.NativeEndian.Uint64(owner[28:36]) ||
			binary.NativeEndian.Uint64(entry[28:36]) > generation ||
			binary.NativeEndian.Uint32(owner[36:40]) != protocol {
			continue
		}
		family := binary.NativeEndian.Uint32(owner[40:44])
		if family != unix.AF_INET && family != unix.AF_INET6 {
			continue
		}
		flag := byte(2) // INP_IPV6
		if src.Is4() {
			flag = 1 // INP_IPV4
		}
		if entry[44]&flag == 0 || binary.BigEndian.Uint16(entry[18:20]) != srcPort ||
			!darwinAddrMatchesOrUnspecified(entry[64:80], src) {
			continue
		}
		foreignPort := binary.BigEndian.Uint16(entry[16:18])
		if dst.IsValid() && !(network == "udp" && foreignPort == 0 && darwinBytesAreZero(entry[48:64])) &&
			(foreignPort != dstPort || !darwinAddrMatches(entry[48:64], dst)) {
			continue
		}
		// e_pid is populated only for delegated sockets; ordinary sockets use last_pid.
		pid := int32(binary.NativeEndian.Uint32(owner[72:76]))
		if pid == 0 {
			pid = int32(binary.NativeEndian.Uint32(owner[68:72]))
		}
		if pid <= 0 {
			continue
		}
		if found != 0 && found != pid {
			return 0, errors.New("ambiguous process match")
		}
		found = pid
	}
	if !complete {
		return 0, invalid
	}
	return found, nil
}

func darwinAddrMatches(raw []byte, addr netip.Addr) bool {
	if addr.Is4() {
		ip := addr.As4()
		return bytes.Equal(raw[12:16], ip[:])
	}
	ip := addr.As16()
	return bytes.Equal(raw, ip[:])
}

func darwinAddrMatchesOrUnspecified(raw []byte, addr netip.Addr) bool {
	if darwinAddrMatches(raw, addr) {
		return true
	}
	if addr.Is4() {
		return darwinBytesAreZero(raw[12:16])
	}
	return darwinBytesAreZero(raw)
}

func darwinBytesAreZero(raw []byte) bool {
	for _, value := range raw {
		if value != 0 {
			return false
		}
	}
	return true
}

func darwinProcessPath(pid int32) (string, error) {
	buf := make([]byte, unix.PathMax)
	n, err := darwinProcPIDPath(pid, buf)
	if err != nil {
		return "", err
	}
	if n <= 0 {
		return "", errors.New("empty process path")
	}
	return strings.TrimRight(string(buf[:n]), "\x00"), nil
}

func darwinProcPIDPath(pid int32, buf []byte) (int, error) {
	r0, _, errno := syscall_syscall6(libc_proc_pidpath_trampoline_addr, uintptr(pid), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0, 0)
	if errno != 0 {
		return 0, errno
	}
	return int(r0), nil
}

var libc_proc_pidpath_trampoline_addr uintptr

//go:cgo_import_dynamic libc_proc_pidpath proc_pidpath "/usr/lib/libproc.dylib"

// Implemented in the runtime package (runtime/sys_darwin.go).
func syscall_syscall6(fn, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2 uintptr, err syscall.Errno)

//go:linkname syscall_syscall6 syscall.syscall6
