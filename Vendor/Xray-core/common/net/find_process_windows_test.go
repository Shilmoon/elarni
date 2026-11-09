//go:build windows

package net

import (
	"bytes"
	"encoding/binary"
	"io"
	"net/netip"
	"os"
	"testing"
	"time"
)

// A VPN adapter or IPv6 address can appear while the previous snapshot is fresh.
// Missing that source must not silently send an excluded process through the VPN.
func TestWindowsProcessLookupRefreshesMissingLocalAddress(t *testing.T) {
	previous := localIPCache.Load()
	t.Cleanup(func() { localIPCache.Store(previous) })
	for _, ip := range []string{"127.0.0.1", "::1"} {
		t.Run(ip, func(t *testing.T) {
			listener, err := Listen("tcp", JoinHostPort(ip, "0"))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			conn, err := Dial("tcp", listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			localIPCache.Store(&localIPCacheEntry{lastUpdate: time.Now()})
			source := conn.LocalAddr().(*TCPAddr)
			target := conn.RemoteAddr().(*TCPAddr)
			pid, _, _, err := FindProcess("tcp", source.IP.String(), uint16(source.Port), target.IP.String(), uint16(target.Port))
			if err != nil || pid != os.Getpid() {
				t.Fatalf("fresh cache hid local socket: pid=%d, err=%v", pid, err)
			}
			if local, err := IsLocal(ParseAddress("224.0.0.1").IP()); err != nil || local {
				t.Fatalf("non-local source accepted: local=%v, err=%v", local, err)
			}
		})
	}
}

// A client can write and close its side before routing has sniffed its first
// bytes; the socket is then in FIN_WAIT_2 but still belongs to the app.
func TestWindowsProcessLookupFindsHalfClosedClient(t *testing.T) {
	listener, err := Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	conn, err := Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	server, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	if err := conn.(*TCPConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := server.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the half-close did not arrive: %v", err)
	}
	source := conn.LocalAddr().(*TCPAddr)
	target := conn.RemoteAddr().(*TCPAddr)
	pid, _, _, err := FindProcess("tcp", source.IP.String(), uint16(source.Port), target.IP.String(), uint16(target.Port))
	if err != nil || pid != os.Getpid() {
		t.Fatalf("half-closed client not found: pid=%d, err=%v", pid, err)
	}
}

// ABI field order comes from Microsoft's MIB_TCP{,6}ROW_OWNER_PID. These
// independent rows exercise both address and port reuse by distinct processes.
func TestWindowsTCPProcessLookupMatchesRemoteEndpoint(t *testing.T) {
	for _, ipv6 := range []bool{false, true} {
		name, family, local, first, second := "IPv4", AddressFamilyIPv4, "127.0.0.1", "192.0.2.1", "192.0.2.2"
		if ipv6 {
			name, family, local, first, second = "IPv6", AddressFamilyIPv6, "::1", "2001:db8::1", "2001:db8::2"
		}
		t.Run(name, func(t *testing.T) {
			src, dst, other := netip.MustParseAddr(local), netip.MustParseAddr(first), netip.MustParseAddr(second)
			var table bytes.Buffer
			write := func(value any) {
				if err := binary.Write(&table, binary.LittleEndian, value); err != nil {
					t.Fatal(err)
				}
			}
			write(uint32(3))
			for index, remote := range []netip.Addr{dst, dst, other} {
				port := uint16(443)
				if index == 1 {
					port = 8443
				}
				localPort := [4]byte{0xc0, 0x00}
				remotePort := [4]byte{byte(port >> 8), byte(port)}
				if ipv6 {
					write(src.As16())
					write(uint32(0))
					write(localPort)
					write(remote.As16())
					write(uint32(0))
					write(remotePort)
					write(uint32(5))
					write(uint32(index + 10))
				} else {
					write(uint32(5))
					write(src.As4())
					write(localPort)
					write(remote.As4())
					write(remotePort)
					write(uint32(index + 10))
				}
			}
			lookup := newSearcher(Network_TCP, family)
			for _, target := range []struct {
				address netip.Addr
				port    uint16
				pid     uint32
			}{
				{dst, 443, 10}, {dst, 8443, 11}, {other, 443, 12},
			} {
				pid, err := lookup.Search(table.Bytes(), src, 49152, target.address, target.port)
				if err != nil || pid != target.pid {
					t.Fatalf("%s:%d: got %d, %v; want %d", target.address, target.port, pid, err, target.pid)
				}
			}
			if _, err := lookup.Search(table.Bytes(), src, 49152, netip.Addr{}, 0); err == nil {
				t.Fatal("ambiguous local tuple selected an arbitrary process")
			}
		})
	}
}

// The keyed lookup names the owner of either end of a connection, and none for addresses that
// no connection has, so FindProcess falls back to the table.
func TestNSIFindsTheOwnerOfATCPConnection(t *testing.T) {
	for _, network := range []struct{ name, address string }{{"tcp4", "127.0.0.1:0"}, {"tcp6", "[::1]:0"}} {
		t.Run(network.name, func(t *testing.T) {
			client, _ := loopbackPair(t, network.name, network.address)
			local, remote := addrPort(client.LocalAddr()), addrPort(client.RemoteAddr())
			if pid := nsiTCPOwner(local, remote); pid != uint32(os.Getpid()) {
				t.Fatalf("client end owner %d, want %d", pid, os.Getpid())
			}
			if pid := nsiTCPOwner(remote, local); pid != uint32(os.Getpid()) {
				t.Fatalf("server end owner %d, want %d", pid, os.Getpid())
			}
			if pid := nsiTCPOwner(local, netip.AddrPortFrom(remote.Addr(), remote.Port()+1)); pid != 0 {
				t.Fatalf("owner %d of a connection that does not exist", pid)
			}
		})
	}
}
