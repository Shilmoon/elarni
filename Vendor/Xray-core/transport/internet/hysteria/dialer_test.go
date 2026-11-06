package hysteria

import (
	"context"
	"net"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/tls"
)

// Releasing a stopped core's stream config must forget its clients and leave
// other configs' clients alone. A dial that fetched a client before the release
// must not reopen QUIC outside the pool (XTLS/Xray-core#7107).
func TestReleaseForgetsOnlyThatConfigsClients(t *testing.T) {
	defer func(d time.Duration) { dialTimeout = d }(dialTimeout)
	dialTimeout = 200 * time.Millisecond // dials outlive their callers, up to this bound
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	// silent reports whether the server got no datagram for a while.
	silent := func() bool {
		server.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		_, _, err := server.ReadFrom(make([]byte, 2048))
		return err != nil
	}
	dial := func(c func(context.Context) error) {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		if c(ctx) == nil {
			t.Fatal("dialed a server that never answers")
		}
	}
	dest := xnet.DestinationFromAddr(server.LocalAddr())
	released := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}, SecuritySettings: &tls.Config{}}
	kept := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}, SecuritySettings: &tls.Config{}}
	for _, streamSettings := range []*internet.MemoryStreamConfig{released, kept} {
		dial(func(ctx context.Context) error { _, err := Dial(ctx, dest, streamSettings); return err })
	}
	defer internet.ReleaseTransport(kept)
	for range 50 {
		if silent() {
			break
		}
	}
	manager.RLock()
	stale := manager.m[dialerConf{dest, released}]
	manager.RUnlock()

	internet.ReleaseTransport(released)
	manager.RLock()
	_, releasedFound := manager.m[dialerConf{dest, released}]
	_, keptFound := manager.m[dialerConf{dest, kept}]
	manager.RUnlock()
	if releasedFound || !keptFound {
		t.Errorf("pooled after release: released config %v, other config %v", releasedFound, keptFound)
	}
	dial(func(ctx context.Context) error { _, err := stale.tcp(ctx); return err })
	if !silent() {
		t.Error("a released client dialed QUIC again")
	}
}
