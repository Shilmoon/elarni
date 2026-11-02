//go:build linux && !android

package net

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxProcessLookupPeerAndAmbiguity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tcp")
	firstRow := "0: 0100007F:C000 010200C0:01BB 01 0:0 0:0 0 0 0 101\n"
	rows := firstRow +
		"1: 0100007F:C000 020200C0:01BB 01 0:0 0:0 0 0 0 102\n"
	if err := os.WriteFile(path, []byte(rows), 0600); err != nil {
		t.Fatal(err)
	}
	for remote, expected := range map[string]string{"010200C0:01BB": "101", "020200C0:01BB": "102", "030200C0:01BB": ""} {
		inode, err := findInodeInFile(path, "0100007F:C000", remote, false)
		if err != nil || inode != expected {
			t.Fatalf("%s: inode=%s err=%v", remote, inode, err)
		}
	}
	if _, err := findInodeInFile(path, "0100007F:C000", "", false); err == nil {
		t.Fatal("missing destination chose between ambiguous TCP sockets")
	}
	if err := os.WriteFile(path, []byte(firstRow), 0600); err != nil {
		t.Fatal(err)
	}
	if inode, err := findInodeInFile(path, "0100007F:C000", "", false); err != nil || inode != "101" {
		t.Fatalf("unique TCP socket without destination: inode=%s err=%v", inode, err)
	}
	rows = "0: 00000000:C000 00000000:0000 07 0:0 0:0 0 0 0 101\n" +
		"1: 00000000:C000 00000000:0000 07 0:0 0:0 0 0 0 102\n"
	if err := os.WriteFile(path, []byte(rows), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := findInodeInFile(path, "0100007F:C000", "010200C0:01BB", true); err == nil {
		t.Fatal("ambiguous wildcard sockets chose an arbitrary process")
	}
}

// Apps open many connections in a row. Once a process owned a socket, finding
// its next one must not readlink every open file on the host (14 ms at 10k fds).
func TestLinuxRecentOwnerSkipsTheFullScan(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	lookup := func() {
		t.Helper()
		client, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		local, remote := client.LocalAddr().(*net.TCPAddr), listener.Addr().(*net.TCPAddr)
		pid, _, _, err := FindProcess("tcp", "127.0.0.1", uint16(local.Port), "127.0.0.1", uint16(remote.Port))
		if err != nil || pid != os.Getpid() {
			t.Fatalf("pid=%d err=%v", pid, err)
		}
	}
	lookup()
	own, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	readLink = func(path string) (string, error) { reads++; return os.Readlink(path) }
	defer func() { readLink = os.Readlink }()
	lookup()
	// Our own descriptors, the new client socket, and the exe link.
	if reads > len(own)+2 {
		t.Fatalf("lookup read %d links; this process has %d descriptors", reads, len(own))
	}
}

// An unconnected application's UDP socket stays wildcard-bound in /proc even
// though its outgoing packet has the selected interface address.
func TestLinuxWildcardUDPProcess(t *testing.T) {
	for _, network := range []string{"udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			ip := "127.0.0.1"
			if network == "udp6" {
				ip = "::1"
			}
			peer, err := net.ListenUDP(network, &net.UDPAddr{IP: net.ParseIP(ip)})
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			client, err := net.ListenUDP(network, &net.UDPAddr{})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if _, err := client.WriteToUDP([]byte("fixture"), peer.LocalAddr().(*net.UDPAddr)); err != nil {
				t.Fatal(err)
			}
			pid, _, _, err := FindProcess("udp", ip, uint16(client.LocalAddr().(*net.UDPAddr).Port), ip, uint16(peer.LocalAddr().(*net.UDPAddr).Port))
			if err != nil || pid != os.Getpid() {
				t.Fatalf("pid=%d err=%v", pid, err)
			}
			pid, _, _, err = FindProcess("udp", ip, uint16(client.LocalAddr().(*net.UDPAddr).Port), "", 0)
			if err != nil || pid != os.Getpid() {
				t.Fatalf("UDP without destination: pid=%d err=%v", pid, err)
			}
		})
	}
}
