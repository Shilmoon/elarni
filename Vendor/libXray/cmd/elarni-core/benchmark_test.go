//go:build elarni_benchmark

package main

import (
	"context"
	"net"
	"syscall"
	"testing"

	xnet "github.com/xtls/xray-core/common/net"
)

func TestBenchmarkResolverCoversXrayAlias(t *testing.T) {
	if xnet.DefaultResolver != net.DefaultResolver || !net.DefaultResolver.PreferGo || net.DefaultResolver.Dial == nil {
		t.Fatal("standard and Xray DNS must share the interface-bound resolver")
	}
}

func TestBenchmarkRejectsLiveLoopbackOutbounds(t *testing.T) {
	for _, address := range []string{"127.0.0.1:8080", "[::1]:8080"} {
		if benchmarkController(nil, false)("tcp", address, nil) == nil {
			t.Fatal("live profiles must not reach a working local proxy")
		}
		if err := benchmarkController(nil, true)("tcp", address, nil); err != nil {
			t.Fatal("loopback fixtures must remain usable", err)
		}
	}
}

// No packets leave the machine: Control runs before bind/connect. Exercise real
// OS socket options for both families and both stream/datagram sockets.
func TestBenchmarkBindingFailureStopsSocket(t *testing.T) {
	invalid := &net.Interface{Name: "elarni-no-such-interface", Index: 0x7ffffffe}
	for _, network := range []string{"tcp4", "tcp6", "udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			called := false
			lc := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
				called = true
				return benchmarkController(invalid, false)(network, address, raw)
			}}
			var err error
			if network[:3] == "tcp" {
				var listener net.Listener
				listener, err = lc.Listen(context.Background(), network, ":0")
				if listener != nil {
					listener.Close()
				}
			} else {
				var listener net.PacketConn
				listener, err = lc.ListenPacket(context.Background(), network, ":0")
				if listener != nil {
					listener.Close()
				}
			}
			if !called || err == nil {
				t.Fatalf("invalid interface must prevent socket creation; controller called=%v, err=%v", called, err)
			}
		})
	}
}
