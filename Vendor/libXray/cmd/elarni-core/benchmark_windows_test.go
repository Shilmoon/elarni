//go:build elarni_benchmark && windows

package main

import (
	"context"
	"net"
	"syscall"
	"testing"

	"golang.org/x/sys/windows"
)

// Control runs before bind/connect, so binding must not depend on a local
// address. A valid interface must allow every socket family and type.
func TestBenchmarkBindingAcceptsValidInterface(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	var loopback *net.Interface
	for i := range interfaces {
		if interfaces[i].Flags&net.FlagLoopback != 0 && interfaces[i].Flags&net.FlagUp != 0 {
			loopback = &interfaces[i]
			break
		}
	}
	if loopback == nil {
		t.Skip("no loopback interface")
	}
	for _, network := range []string{"tcp4", "tcp6", "udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			lc := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
				return benchmarkController(loopback, false)(network, address, raw)
			}}
			var closer interface{ Close() error }
			if network[:3] == "tcp" {
				closer, err = lc.Listen(context.Background(), network, ":0")
			} else {
				closer, err = lc.ListenPacket(context.Background(), network, ":0")
			}
			if err != nil {
				t.Fatalf("valid interface must allow socket creation: %v", err)
			}
			closer.Close()
		})
	}
}

func loopbackInterface(t *testing.T) *net.Interface {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	for i := range interfaces {
		if interfaces[i].Flags&net.FlagLoopback != 0 && interfaces[i].Flags&net.FlagUp != 0 {
			return &interfaces[i]
		}
	}
	t.Skip("no loopback interface")
	return nil
}

// Xray's UDP sockets are dual-stack, and IPv4 sent from one follows IP_UNICAST_IF,
// not IPV6_UNICAST_IF: bound to loopback, it must have no route to a public address.
func TestBenchmarkBindingHoldsIPv4OnADualStackSocket(t *testing.T) {
	lc := net.ListenConfig{Control: benchmarkController(loopbackInterface(t), false)}
	conn, err := lc.ListenPacket(context.Background(), "udp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	raw, err := conn.(*net.UDPConn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var connectErr error
	raw.Control(func(fd uintptr) {
		target := &windows.SockaddrInet6{Port: 9}
		copy(target.Addr[:], net.ParseIP("192.0.2.1").To16())
		connectErr = windows.Connect(windows.Handle(fd), target) // A UDP connect sends nothing.
	})
	if connectErr == nil {
		t.Fatal("a dual-stack socket bound to loopback still routes IPv4 to 192.0.2.1")
	}
}
