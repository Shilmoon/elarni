package grpc

import (
	"context"
	"runtime"
	"testing"
	"time"
	"weak"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/transport/internet"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
)

// A pooled client's dialer holds the first dial's context, and with it the
// core. Releasing a stopped core's stream config must close and forget its
// clients, and leave other configs' clients alone.
func TestReleaseForgetsOnlyThatConfigsClients(t *testing.T) {
	dest := net.TCPDestination(net.LocalHostIP, net.Port(1))
	released := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}}
	kept := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}}
	releasedConn, err := getGrpcClient(context.Background(), dest, released)
	if err != nil {
		t.Fatal(err)
	}
	keptConn, err := getGrpcClient(context.Background(), dest, kept)
	if err != nil {
		t.Fatal(err)
	}
	defer internet.ReleaseTransport(kept)

	internet.ReleaseTransport(released)
	globalDialerAccess.Lock()
	_, releasedFound := globalDialerMap[dialerConf{dest, released}]
	_, keptFound := globalDialerMap[dialerConf{dest, kept}]
	globalDialerAccess.Unlock()
	if releasedFound || releasedConn.GetState() != connectivity.Shutdown {
		t.Errorf("released client: pooled %v, state %v", releasedFound, releasedConn.GetState())
	}
	if !keptFound || keptConn.GetState() == connectivity.Shutdown {
		t.Errorf("other config's client: pooled %v, state %v", keptFound, keptConn.GetState())
	}
}

// gRPC's idle manager stops its timer on Close, and a stopped runtime timer
// keeps its closure, and so the closed ClientConn, until the old 30 min idle
// deadline. Through its dialer, the client must keep neither its first dial's
// context nor that session's outbound: both reach the core.
func TestClosedClientKeepsNoDialSession(t *testing.T) {
	config := &internet.MemoryStreamConfig{ProtocolName: protocolName, ProtocolSettings: &Config{}}
	client, values, outbound := dialWithSession(t, config)
	internet.ReleaseTransport(config)
	for deadline := time.Now().Add(time.Second); (values.Value() != nil || outbound.Value() != nil) && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
		runtime.GC()
	}
	if values.Value() != nil {
		t.Error("a closed client keeps its first dial's context reachable")
	}
	if outbound.Value() != nil {
		t.Error("a closed client keeps its first session's outbound reachable")
	}
	runtime.KeepAlive(client) // as gRPC's stopped idle timer does
}

type sessionKey struct{}

func dialWithSession(t *testing.T, config *internet.MemoryStreamConfig) (*grpc.ClientConn, weak.Pointer[[64]byte], weak.Pointer[session.Outbound]) {
	values, outbound := new([64]byte), &session.Outbound{Name: "vless"}
	ctx := session.ContextWithOutbounds(context.WithValue(context.Background(), sessionKey{}, values), []*session.Outbound{outbound})
	client, err := getGrpcClient(ctx, net.TCPDestination(net.LocalHostIP, net.Port(1)), config)
	if err != nil {
		t.Fatal(err)
	}
	return client, weak.Make(values), weak.Make(outbound)
}
