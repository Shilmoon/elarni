//go:build (darwin && !ios) || windows || (linux && !android)

package net

import (
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"runtime"
	"syscall"
	"testing"
	"time"
)

func loopbackPair(t *testing.T, network, address string) (client, server net.Conn) {
	t.Helper()
	listener, err := net.Listen(network, address)
	if err != nil {
		t.Skipf("no %s loopback: %v", network, err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, _ := listener.Accept()
		accepted <- connection
	}()
	client, err = net.Dial(network, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	server = <-accepted
	if server == nil {
		t.Fatal("accept failed")
	}
	t.Cleanup(func() { client.Close(); server.Close() })
	return client, server
}

func addrPort(addr net.Addr) netip.AddrPort {
	value := addr.(*net.TCPAddr).AddrPort()
	return netip.AddrPortFrom(value.Addr().Unmap(), value.Port())
}

func unmapped(connection TCPConnection) TCPConnection {
	connection.Local = netip.AddrPortFrom(connection.Local.Addr().Unmap(), connection.Local.Port())
	connection.Remote = netip.AddrPortFrom(connection.Remote.Addr().Unmap(), connection.Remote.Port())
	return connection
}

// The core finds a listed app's connections that were open before the tunnel started: both
// ends of a connection, with the program that holds each.
func TestEstablishedTCPConnectionsListThisProgram(t *testing.T) {
	for _, c := range []struct{ network, address string }{{"tcp4", "127.0.0.1:0"}, {"tcp6", "[::1]:0"}} {
		t.Run(c.network, func(t *testing.T) {
			client, server := loopbackPair(t, c.network, c.address)
			want := map[TCPConnection]bool{
				{Local: addrPort(client.LocalAddr()), Remote: addrPort(client.RemoteAddr()), PID: os.Getpid()}: false,
				{Local: addrPort(server.LocalAddr()), Remote: addrPort(server.RemoteAddr()), PID: os.Getpid()}: false,
			}
			connections, err := EstablishedTCPConnections()
			if err != nil {
				t.Fatal(err)
			}
			for _, connection := range connections {
				if _, ok := want[unmapped(connection)]; ok {
					want[unmapped(connection)] = true
				}
			}
			for connection, found := range want {
				if !found {
					t.Errorf("%+v is not among %d connections", connection, len(connections))
				}
			}
		})
	}
}

// resetUnavailable reports whether err says this process may not reset connections here: no
// administrator on Windows, no CAP_NET_ADMIN or no kernel support on Linux, never on macOS.
func resetUnavailable(err error) bool {
	if errors.Is(err, ErrResetUnsupported) {
		return true
	}
	var code syscall.Errno
	if !errors.As(err, &code) {
		return false
	}
	switch runtime.GOOS {
	case "windows":
		return code == 5 || code == 317 // ERROR_ACCESS_DENIED, ERROR_MR_MID_NOT_FOUND without elevation
	case "linux":
		return code == syscall.EPERM || code == syscall.EOPNOTSUPP
	}
	return false
}

// A reset connection fails at once, so the app reconnects; where the system refuses, the
// connection keeps working.
func TestResetTCPConnection(t *testing.T) {
	client, server := loopbackPair(t, "tcp4", "127.0.0.1:0")
	go func() { _, _ = io.Copy(server, server) }()
	err := ResetTCPConnection(TCPConnection{Local: addrPort(client.LocalAddr()), Remote: addrPort(client.RemoteAddr())})
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	_, writeErr := client.Write([]byte("x"))
	buf := make([]byte, 1)
	_, readErr := io.ReadFull(client, buf)
	switch {
	case err == nil:
		if writeErr == nil && readErr == nil {
			t.Fatal("the reset connection still works")
		}
		var timeout net.Error
		if errors.As(readErr, &timeout) && timeout.Timeout() {
			t.Fatalf("the reset connection hung: %v", readErr)
		}
		t.Logf("reset: write %v, read %v", writeErr, readErr)
	case resetUnavailable(err):
		if writeErr != nil || readErr != nil {
			t.Fatalf("a refused reset broke the connection: %v %v", writeErr, readErr)
		}
		t.Logf("reset unavailable here: %v", err)
	default:
		t.Fatalf("reset: %v", err)
	}
}
