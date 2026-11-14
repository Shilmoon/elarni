//go:build linux && !android

package net

import (
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestProcNetTCPReadsEstablishedEntries(t *testing.T) {
	table := []byte(`  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1111 1 0000000000000000 100 0 0 10 0
   1: 0100007F:C350 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 20 4 30 10 -1
   2: 0100007F:C351 0100007F:1F90 06 00000000:00000000 03:00000000 00000000     0        0 0 3 0000000000000000
   3: 0100007F:C350 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 20 4 30 10 -1
`)
	// The last line repeats a connection: the kernel does that when sockets open or close while
	// the table is read in parts, and one reset and one listed entry per connection is enough.
	entries := procNetTCP(table)
	if len(entries) != 1 || entries[0].inode != "2222" ||
		entries[0].Local != netip.MustParseAddrPort("127.0.0.1:50000") || entries[0].Remote != netip.MustParseAddrPort("127.0.0.1:8080") {
		t.Fatalf("entries %+v", entries)
	}
	ipv6 := []byte(`  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:C350 0000000000000000FFFF00000100007F:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 3333 1 0000000000000000 20 4 30 10 -1
`)
	entries = procNetTCP(ipv6)
	if len(entries) != 1 || entries[0].Local != netip.MustParseAddrPort("[::1]:50000") ||
		entries[0].Remote != netip.MustParseAddrPort("[::ffff:127.0.0.1]:443") {
		t.Fatalf("entries %+v", entries)
	}
}

// The kernel writes the table in pieces, and one that changes between two of them can repeat a
// socket. A connection listed twice would be reset and shown twice.
func TestProcNetTCPListsARepeatedSocketOnce(t *testing.T) {
	table := []byte(`  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:C350 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 20 4 30 10 -1
   1: 0100007F:C352 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 4444 1 0000000000000000 20 4 30 10 -1
   1: 0100007F:C350 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 20 4 30 10 -1
`)
	entries := procNetTCP(table)
	if len(entries) != 2 || entries[0].inode != "2222" || entries[1].inode != "4444" {
		t.Fatalf("entries %+v", entries)
	}
}

// socketInode reads the inode of a connection's socket from this process's descriptors.
func socketInode(t *testing.T, connection net.Conn) uint32 {
	t.Helper()
	raw, err := connection.(syscall.Conn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var link string
	var readErr error
	if err := raw.Control(func(fd uintptr) { link, readErr = os.Readlink("/proc/self/fd/" + strconv.Itoa(int(fd))) }); err != nil {
		t.Fatal(err)
	}
	if readErr != nil {
		t.Fatal(readErr)
	}
	inode, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimPrefix(link, "socket:["), "]"), 10, 32)
	if err != nil {
		t.Fatalf("socket link %q: %v", link, err)
	}
	return uint32(inode)
}

// Lookups ask the kernel for a TCP connection's socket by its addresses. A listening socket,
// which the kernel offers when no connection has them, is not the connection's.
func TestTCPSocketInodeFindsTheConnection(t *testing.T) {
	dualStack := net.Dialer{LocalAddr: &net.TCPAddr{IP: net.IPv6zero}}
	for _, c := range []struct {
		name, network, address string
		dial                   func(network, address string) (net.Conn, error)
	}{
		{"tcp4", "tcp4", "127.0.0.1:0", net.Dial},
		{"tcp6", "tcp6", "[::1]:0", net.Dial},
		{"dual-stack", "tcp4", "127.0.0.1:0", func(_, address string) (net.Conn, error) { return dualStack.Dial("tcp", address) }},
	} {
		t.Run(c.name, func(t *testing.T) {
			listener, err := net.Listen(c.network, c.address)
			if err != nil {
				t.Skipf("no %s loopback: %v", c.network, err)
			}
			defer listener.Close()
			client, err := c.dial(c.network, listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			server, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			local, remote := addrPort(client.LocalAddr()), addrPort(client.RemoteAddr())
			for _, end := range []struct {
				connection    net.Conn
				local, remote netip.AddrPort
			}{{client, local, remote}, {server, remote, local}} {
				inode, err := tcpSocketInode(end.local, end.remote)
				if want := socketInode(t, end.connection); err != nil || inode != want {
					t.Fatalf("%v -> %v: inode %d, %v; want %d", end.local, end.remote, inode, err, want)
				}
			}
			if inode, err := tcpSocketInode(addrPort(listener.Addr()), netip.AddrPortFrom(remote.Addr(), 9)); err != nil || inode != 0 {
				t.Fatalf("a listener's address gave inode %d, %v", inode, err)
			}
		})
	}
}
