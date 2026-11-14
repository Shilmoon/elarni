//go:build linux && !android

package net

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// EstablishedTCPConnections lists the established TCP connections of the programs whose
// descriptors this process may read: all of them as root.
func EstablishedTCPConnections() ([]TCPConnection, error) {
	byInode := map[string][]int{}
	var connections []TCPConnection
	for _, file := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		data, err := os.ReadFile(file)
		if err != nil {
			if os.IsNotExist(err) {
				continue // no IPv6
			}
			return nil, err
		}
		for _, entry := range procNetTCP(data) {
			byInode["socket:["+entry.inode+"]"] = append(byInode["socket:["+entry.inode+"]"], len(connections))
			connections = append(connections, entry.TCPConnection)
		}
	}
	if len(connections) == 0 {
		return nil, nil
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || !entry.IsDir() {
			continue
		}
		fdPath := "/proc/" + entry.Name() + "/fd"
		descriptors, err := os.ReadDir(fdPath)
		if err != nil {
			continue // another user's process
		}
		for _, descriptor := range descriptors {
			link, err := readLink(fdPath + "/" + descriptor.Name())
			if err != nil {
				continue
			}
			for _, index := range byInode[link] {
				if connections[index].PID == 0 {
					connections[index].PID = pid
				}
			}
		}
	}
	owned := connections[:0]
	for _, connection := range connections {
		if connection.PID != 0 {
			owned = append(owned, connection)
		}
	}
	return owned, nil
}

type procNetEntry struct {
	TCPConnection
	inode string
}

// procNetTCP reads the established entries of /proc/net/tcp or tcp6, each connection once:
// "sl local remote st ... inode".
func procNetTCP(data []byte) []procNetEntry {
	var entries []procNetEntry
	seen := map[TCPConnection]struct{}{}
	lines := bufio.NewScanner(bytes.NewReader(data))
	lines.Buffer(make([]byte, 0, 4096), 1<<20)
	lines.Scan() // the header
	for lines.Scan() {
		fields := strings.Fields(lines.Text())
		if len(fields) < 10 || fields[3] != "01" || fields[9] == "0" { // TCP_ESTABLISHED
			continue
		}
		local, okLocal := procNetAddress(fields[1])
		remote, okRemote := procNetAddress(fields[2])
		connection := TCPConnection{Local: local, Remote: remote}
		// A table read in parts while sockets open and close can hold a connection twice.
		if _, twice := seen[connection]; okLocal && okRemote && !twice {
			seen[connection] = struct{}{}
			entries = append(entries, procNetEntry{connection, fields[9]})
		}
	}
	return entries
}

// procNetAddress reads "0100007F:0050": the address as 32-bit words in host order, the port in hex.
func procNetAddress(field string) (netip.AddrPort, bool) {
	address, port, ok := strings.Cut(field, ":")
	raw, err := hex.DecodeString(address)
	value, portErr := strconv.ParseUint(port, 16, 16)
	if !ok || err != nil || portErr != nil || len(raw) != 4 && len(raw) != 16 {
		return netip.AddrPort{}, false
	}
	for word := 0; word < len(raw); word += 4 {
		binary.BigEndian.PutUint32(raw[word:], binary.NativeEndian.Uint32(raw[word:]))
	}
	addr, _ := netip.AddrFromSlice(raw)
	return netip.AddrPortFrom(addr, uint16(value)), true
}

// ResetTCPConnection closes a connection with SOCK_DESTROY, which needs CAP_NET_ADMIN and a
// kernel built with CONFIG_INET_DIAG_DESTROY; the program's socket fails with ECONNABORTED.
func ResetTCPConnection(connection TCPConnection) error {
	reply, err := sockDiag(unix.SOCK_DESTROY, unix.NLM_F_ACK, 1<<unix.BPF_TCP_ESTABLISHED, connection.Local, connection.Remote)
	if err != nil {
		return err
	}
	if binary.NativeEndian.Uint16(reply[4:]) != unix.NLMSG_ERROR {
		return syscall.EPROTO
	}
	return sockDiagError(reply)
}

// tcpSocketInode asks the kernel for the TCP socket from local to remote by its addresses, as
// ss does for one socket, which needs no privilege and reads no table: its inode, or 0 when the
// kernel has no such connection. An IPv6 socket without IPV6_V6ONLY that talks IPv4 is keyed by
// the IPv4-mapped addresses.
func tcpSocketInode(local, remote netip.AddrPort) (uint32, error) {
	inode, err := tcpSocketInodeOf(local, remote)
	if err != nil || inode != 0 || !local.Addr().Is4() || !remote.Addr().Is4() {
		return inode, err
	}
	mapped := func(address netip.AddrPort) netip.AddrPort {
		return netip.AddrPortFrom(netip.AddrFrom16(address.Addr().As16()), address.Port())
	}
	return tcpSocketInodeOf(mapped(local), mapped(remote))
}

func tcpSocketInodeOf(local, remote netip.AddrPort) (uint32, error) {
	reply, err := sockDiag(unix.SOCK_DIAG_BY_FAMILY, 0, ^uint32(0), local, remote)
	if err != nil {
		return 0, err
	}
	if binary.NativeEndian.Uint16(reply[4:]) == unix.NLMSG_ERROR {
		if err := sockDiagError(reply); err != unix.ENOENT {
			return 0, err
		}
		return 0, nil
	}
	// struct inet_diag_msg: family, state, timer, retrans, struct inet_diag_sockid, expires,
	// rqueue, wqueue, uid, inode.
	message := reply[unix.NLMSG_HDRLEN:]
	if binary.NativeEndian.Uint16(reply[4:]) != unix.SOCK_DIAG_BY_FAMILY || len(message) < 72 {
		return 0, syscall.EPROTO
	}
	// The kernel answers with a listening socket when no connection has the addresses.
	peer := message[24:40]
	if binary.BigEndian.Uint16(message[6:8]) != remote.Port() || !diagAddrIs(peer, remote.Addr(), message[0]) {
		return 0, nil
	}
	return binary.NativeEndian.Uint32(message[68:72]), nil
}

func diagAddrIs(raw []byte, addr netip.Addr, family byte) bool {
	if family == unix.AF_INET {
		ip := addr.As4()
		return addr.Is4() && bytes.Equal(raw[:4], ip[:])
	}
	ip := addr.As16()
	return bytes.Equal(raw, ip[:])
}

// sockDiag sends one NETLINK_SOCK_DIAG request of kind for the TCP socket from local to remote,
// and returns the kernel's first reply message.
func sockDiag(kind, flags uint16, states uint32, local, remote netip.AddrPort) ([]byte, error) {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_SOCK_DIAG)
	if err != nil {
		return nil, err
	}
	defer unix.Close(fd)
	timeout := unix.NsecToTimeval(int64(time.Second))
	if err := unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &timeout); err != nil {
		return nil, err
	}
	// struct nlmsghdr, then struct inet_diag_req_v2 with its struct inet_diag_sockid.
	request := make([]byte, unix.NLMSG_HDRLEN+56)
	binary.NativeEndian.PutUint32(request[0:], uint32(len(request)))
	binary.NativeEndian.PutUint16(request[4:], kind)
	binary.NativeEndian.PutUint16(request[6:], unix.NLM_F_REQUEST|flags)
	binary.NativeEndian.PutUint32(request[8:], 1)
	body := request[unix.NLMSG_HDRLEN:]
	body[0] = unix.AF_INET6
	if local.Addr().Is4() && remote.Addr().Is4() {
		body[0] = unix.AF_INET
	}
	body[1] = unix.IPPROTO_TCP
	binary.NativeEndian.PutUint32(body[4:], states)
	binary.BigEndian.PutUint16(body[8:], local.Port())
	binary.BigEndian.PutUint16(body[10:], remote.Port())
	put := func(at []byte, addr netip.Addr) {
		if body[0] == unix.AF_INET {
			ip := addr.As4()
			copy(at, ip[:])
		} else {
			ip := addr.As16()
			copy(at, ip[:])
		}
	}
	put(body[12:28], local.Addr())
	put(body[28:44], remote.Addr())
	binary.NativeEndian.PutUint32(body[48:], ^uint32(0)) // INET_DIAG_NOCOOKIE
	binary.NativeEndian.PutUint32(body[52:], ^uint32(0))
	if err := unix.Sendto(fd, request, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return nil, err
	}
	reply := make([]byte, 4096)
	n, _, err := unix.Recvfrom(fd, reply, 0)
	if err != nil {
		return nil, err
	}
	if n < unix.NLMSG_HDRLEN+4 || int(binary.NativeEndian.Uint32(reply[0:])) > n {
		return nil, syscall.EPROTO
	}
	return reply[:binary.NativeEndian.Uint32(reply[0:])], nil
}

// sockDiagError returns the error an NLMSG_ERROR reply carries, nil for an acknowledgement.
func sockDiagError(reply []byte) error {
	if code := int32(binary.NativeEndian.Uint32(reply[unix.NLMSG_HDRLEN:])); code != 0 {
		return syscall.Errno(-code)
	}
	return nil
}
