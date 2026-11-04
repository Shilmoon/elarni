package splithttp_test

import (
	"context"
	"io"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

// Over HTTP/3, flows share a QUIC connection. Three downloads the app stopped reading held
// the connection window with their unread bytes, so every other flow on it froze.
func TestH3StalledDownloadsLeaveTheConnectionUsable(t *testing.T) {
	port := freeUDPPort(t)
	server := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x"}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{Certificate: []*tls.Certificate{certificate()}, NextProtocol: []string{"h3"}},
	}
	ln, err := splithttp.ListenXH(context.Background(), net.LocalHostIP, port, server, func(conn stat.Connection) {
		go func() { // the client's byte starts an endless download
			defer conn.Close()
			if _, err := conn.Read(make([]byte, 1)); err != nil {
				return
			}
			chunk := make([]byte, 64<<10)
			for {
				if _, err := conn.Write(chunk); err != nil {
					return
				}
			}
		}()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "splithttp",
		ProtocolSettings: xhttpSettings(t, `{"path":"/x","mode":"stream-one","xmux":{"maxConcurrency":16}}`),
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true, NextProtocol: []string{"h3"}},
	}
	t.Cleanup(func() { internet.ReleaseTransport(client) })
	dest := net.TCPDestination(net.LocalHostIP, port)
	for range 3 {
		stalled, err := splithttp.Dial(context.Background(), dest, client)
		if err != nil {
			t.Fatal(err)
		}
		defer stalled.Close()
		stalled.Write([]byte{1})
	}
	time.Sleep(time.Second) // the server fills what the stalled downloads may hold
	fresh, err := splithttp.Dial(context.Background(), dest, client)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	fresh.Write([]byte{1})
	got := make(chan error, 1)
	go func() {
		_, err := io.ReadFull(fresh, make([]byte, 1<<20))
		got <- err
	}()
	select {
	case err := <-got:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a fresh download got no megabyte in 5 s")
	}
}
