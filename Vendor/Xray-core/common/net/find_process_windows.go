//go:build windows

package net

import (
	"net"
	"net/netip"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/xtls/xray-core/common/errors"
)

const (
	tcpTableFunc    = "GetExtendedTcpTable"
	tcpTablePidConn = 4
	udpTableFunc    = "GetExtendedUdpTable"
	udpTablePid     = 1
)

var (
	getExTCPTable uintptr
	getExUDPTable uintptr

	once    sync.Once
	initErr error

	// One per network and family: tcp4, tcp6, udp4, udp6.
	transportTables [4]*processTable
)

func initWin32API() error {
	// System32 only: an elevated helper must not load a planted DLL from its directory.
	h, err := windows.LoadLibraryEx("iphlpapi.dll", 0, windows.LOAD_LIBRARY_SEARCH_SYSTEM32)
	if err != nil {
		return errors.New("LoadLibrary iphlpapi.dll failed").Base(err)
	}

	getExTCPTable, err = windows.GetProcAddress(h, tcpTableFunc)
	if err != nil {
		return errors.New("GetProcAddress of ", tcpTableFunc, " failed").Base(err)
	}

	getExUDPTable, err = windows.GetProcAddress(h, udpTableFunc)
	if err != nil {
		return errors.New("GetProcAddress of ", udpTableFunc, " failed").Base(err)
	}

	for i := range transportTables {
		fn, class, family := getExTCPTable, tcpTablePidConn, windows.AF_INET
		network, familyType := Network_TCP, AddressFamilyIPv4
		if i >= 2 {
			fn, class, network = getExUDPTable, udpTablePid, Network_UDP
		}
		if i%2 == 1 {
			family, familyType = windows.AF_INET6, AddressFamilyIPv6
		}
		rowSize := newSearcher(network, familyType).itemSize
		transportTables[i] = &processTable{fetch: func(size uint32) ([]byte, error) {
			return getTransportTable(fn, family, class, rowSize, size)
		}}
	}
	return nil
}

func FindProcess(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (PID int, Name string, AbsolutePath string, err error) {
	once.Do(func() {
		initErr = initWin32API()
	})
	if initErr != nil {
		return 0, "", "", initErr
	}
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
	ip := net.ParseIP(srcIP)
	port := int(srcPort)

	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return 0, "", "", errors.New("invalid IP address")
	}
	addr = addr.Unmap()
	var dstAddr netip.Addr
	if network == "tcp" && destIP != "" && destPort != 0 {
		dstAddr, err = netip.ParseAddr(destIP)
		if err != nil {
			return 0, "", "", errors.New("invalid destination IP address")
		}
		dstAddr = dstAddr.Unmap()
	}

	family := windows.AF_INET
	if addr.Is6() {
		family = windows.AF_INET6
	}

	table := 0
	if network == "udp" {
		table = 2
	}
	if family == windows.AF_INET6 {
		table++
	}
	buf, err := transportTables[table].get()
	if err != nil {
		return 0, "", "", err
	}

	networkType := Network_TCP
	if network == "udp" {
		networkType = Network_UDP
	}
	familyType := AddressFamilyIPv4
	if addr.Is6() {
		familyType = AddressFamilyIPv6
	}
	s := newSearcher(networkType, familyType)

	pid, err := s.Search(buf, addr, uint16(port), dstAddr, destPort)
	if err != nil {
		return 0, "", "", err
	}
	NameWithPath, err := getExecPathFromPID(pid)
	NameWithPath = filepath.ToSlash(NameWithPath)

	// drop .exe and path
	nameSplit := strings.Split(NameWithPath, "/")
	procName := nameSplit[len(nameSplit)-1]
	procName = strings.TrimSuffix(procName, ".exe")
	return int(pid), procName, NameWithPath, err
}

type searcher struct {
	itemSize   int
	port       int
	ip         int
	ipSize     int
	pid        int
	tcpState   int
	remoteIP   int
	remotePort int
}

func (s *searcher) Search(b []byte, ip netip.Addr, port uint16, dst netip.Addr, dstPort uint16) (uint32, error) {
	n := int(readNativeUint32(b[:4]))
	itemSize := s.itemSize
	var found uint32
	matched := false
	for i := range n {
		row := b[4+itemSize*i : 4+itemSize*(i+1)]

		if s.tcpState >= 0 {
			tcpState := readNativeUint32(row[s.tcpState : s.tcpState+4])
			// MIB_TCP_STATE_ESTAB. A client may close its side before routing
			// runs, so FIN_WAIT1 through LAST_ACK also count when the remote
			// endpoint pins the row to this one connection.
			if tcpState != 5 && (!dst.IsValid() || tcpState < 6 || tcpState > 10) {
				continue
			}
		}

		// according to MSDN, only the lower 16 bits of dwLocalPort are used and the port number is in network endian.
		// this field can be illustrated as follows depends on different machine endianess:
		//     little endian: [ MSB LSB  0   0  ]   interpret as native uint32 is ((LSB<<8)|MSB)
		//       big  endian: [  0   0  MSB LSB ]   interpret as native uint32 is ((MSB<<8)|LSB)
		// so we need an syscall.Ntohs on the lower 16 bits after read the port as native uint32
		srcPort := syscall.Ntohs(uint16(readNativeUint32(row[s.port : s.port+4])))
		if srcPort != port {
			continue
		}

		srcIP, _ := netip.AddrFromSlice(row[s.ip : s.ip+s.ipSize])
		srcIP = srcIP.Unmap()
		// windows binds an unbound udp socket to 0.0.0.0/[::] while first sendto
		if ip != srcIP && (!srcIP.IsUnspecified() || s.tcpState != -1) {
			continue
		}
		if s.tcpState >= 0 && dst.IsValid() {
			remoteIP, _ := netip.AddrFromSlice(row[s.remoteIP : s.remoteIP+s.ipSize])
			remotePort := syscall.Ntohs(uint16(readNativeUint32(row[s.remotePort : s.remotePort+4])))
			if remoteIP.Unmap() != dst || remotePort != dstPort {
				continue
			}
		}

		pid := readNativeUint32(row[s.pid : s.pid+4])
		// A hostname-only TCP target or reused UDP port can lack enough tuple
		// information. Do not apply another application's routing policy.
		if matched && found != pid {
			return 0, errors.New("ambiguous process match")
		}
		found, matched = pid, true
	}
	if matched {
		return found, nil
	}
	return 0, errors.New("not found")
}

func newSearcher(network Network, family AddressFamily) *searcher {
	var itemSize, port, ip, ipSize, pid int
	var remoteIP, remotePort int
	tcpState := -1
	switch network {
	case Network_TCP:
		if family == AddressFamilyIPv4 {
			// struct MIB_TCPROW_OWNER_PID
			itemSize, port, ip, ipSize, pid, tcpState = 24, 8, 4, 4, 20, 0
			remoteIP, remotePort = 12, 16
		}
		if family == AddressFamilyIPv6 {
			// struct MIB_TCP6ROW_OWNER_PID
			itemSize, port, ip, ipSize, pid, tcpState = 56, 20, 0, 16, 52, 48
			remoteIP, remotePort = 24, 44
		}
	case Network_UDP:
		if family == AddressFamilyIPv4 {
			// struct MIB_UDPROW_OWNER_PID
			itemSize, port, ip, ipSize, pid = 12, 4, 0, 4, 8
		}
		if family == AddressFamilyIPv6 {
			// struct MIB_UDP6ROW_OWNER_PID
			itemSize, port, ip, ipSize, pid = 28, 20, 0, 16, 24
		}
	}

	return &searcher{
		itemSize:   itemSize,
		port:       port,
		ip:         ip,
		ipSize:     ipSize,
		pid:        pid,
		tcpState:   tcpState,
		remoteIP:   remoteIP,
		remotePort: remotePort,
	}
}

// getTransportTable reads a socket table. Windows builds the whole table on every call, also
// for a call that only learns the size, so the last size plus room for new sockets comes first.
func getTransportTable(fn uintptr, family int, class int, rowSize int, sizeHint uint32) ([]byte, error) {
	size := max(sizeHint+sizeHint/4+4096, 8)
	for buf := make([]byte, size); ; {
		ptr := unsafe.Pointer(&buf[0])
		err, _, _ := syscall.Syscall6(fn, 6, uintptr(ptr), uintptr(unsafe.Pointer(&size)), 0, uintptr(family), uintptr(class), 0)

		switch err {
		case 0:
			// The table's own length, not the buffer's, so the next size hint does not grow.
			if n := 4 + int(readNativeUint32(buf[:4]))*rowSize; n <= len(buf) {
				return buf[:n], nil
			}
			return nil, errors.New("socket table larger than its buffer")
		case uintptr(syscall.ERROR_INSUFFICIENT_BUFFER):
			buf = make([]byte, size)
		default:
			return nil, errors.New("syscall error: ", int(err))
		}
	}
}

func readNativeUint32(b []byte) uint32 {
	return *(*uint32)(unsafe.Pointer(&b[0]))
}

func getExecPathFromPID(pid uint32) (string, error) {
	// kernel process starts with a colon in order to distinguish with normal processes
	switch pid {
	case 0:
		// reserved pid for system idle process
		return ":System Idle Process", nil
	case 4:
		// reserved pid for windows kernel image
		return ":System", nil
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(h)

	// Most paths fit 1 KiB; a 64 KiB buffer on every lookup was garbage at each new connection.
	var short [512]uint16
	for buf := short[:]; ; buf = make([]uint16, syscall.MAX_LONG_PATH) {
		size := uint32(len(buf))
		err = windows.QueryFullProcessImageName(h, 0, &buf[0], &size)
		if err == windows.ERROR_INSUFFICIENT_BUFFER && len(buf) < syscall.MAX_LONG_PATH {
			continue
		}
		if err != nil {
			return "", err
		}
		return syscall.UTF16ToString(buf[:size]), nil
	}
}
