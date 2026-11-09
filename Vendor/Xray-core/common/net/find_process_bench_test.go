//go:build (darwin && !ios) || windows || (linux && !android)

package net

import (
	"net"
	"os"
	"sync"
	"testing"
)

// loopbackConns opens n TCP connections owned by this process and returns their client ends.
func loopbackConns(tb testing.TB, n int) []*net.TCPConn {
	tb.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { listener.Close() })
	clients := make([]*net.TCPConn, n)
	for i := range clients {
		client, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			tb.Fatal(err)
		}
		server, err := listener.Accept()
		if err != nil {
			tb.Fatal(err)
		}
		clients[i] = client.(*net.TCPConn)
		clients[i].SetLinger(0) // no TIME_WAIT rows left behind to grow later runs' tables
		tb.Cleanup(func() { client.Close(); server.Close() })
	}
	return clients
}

func lookupOwnConn(tb testing.TB, c *net.TCPConn) {
	local, remote := c.LocalAddr().(*net.TCPAddr), c.RemoteAddr().(*net.TCPAddr)
	pid, _, _, err := FindProcess("tcp", "127.0.0.1", uint16(local.Port), "127.0.0.1", uint16(remote.Port))
	if err != nil || pid != os.Getpid() {
		tb.Errorf("pid=%d err=%v", pid, err)
	}
}

// lookupBurst looks up every connection at once, as routing does for a burst of new ones.
func lookupBurst(tb testing.TB, targets []*net.TCPConn) {
	var wg sync.WaitGroup
	for _, c := range targets {
		wg.Go(func() { lookupOwnConn(tb, c) })
	}
	wg.Wait()
}

// A browser holds hundreds of sockets and opens dozens of new connections at once.
func BenchmarkFindProcess(b *testing.B) {
	loopbackConns(b, 500) // 1000 table rows and descriptors, as an idle browser holds
	targets := loopbackConns(b, 64)
	b.Run("single", func(b *testing.B) {
		for b.Loop() {
			lookupOwnConn(b, targets[0])
		}
	})
	b.Run("burst64", func(b *testing.B) {
		for b.Loop() {
			lookupBurst(b, targets)
		}
	})
}
