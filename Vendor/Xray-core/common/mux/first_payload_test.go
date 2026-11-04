package mux

import (
	"context"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/transport/pipe"
)

// Elarni: a client of a server-first protocol (SMTP, MySQL...) sends nothing until the server greets it,
// so the 100 ms wait for its first bytes only delayed the greeting.
func TestServerFirstPortsSkipTheFirstPayloadWait(t *testing.T) {
	silent := session.ContextWithContent(context.Background(), &session.Content{ClientSilent: true})
	for _, c := range []struct {
		ctx  context.Context
		dest net.Destination
		wait bool
	}{
		{context.Background(), net.TCPDestination(net.LocalHostIP, 25), false},
		{context.Background(), net.TCPDestination(net.LocalHostIP, 3306), false},
		{context.Background(), net.TCPDestination(net.LocalHostIP, 443), true},
		{context.Background(), net.UDPDestination(net.LocalHostIP, 25), true},
		// Sniffing already waited for this client and it sent nothing.
		{silent, net.TCPDestination(net.LocalHostIP, 2525), false},
	} {
		reader, _ := pipe.New(pipe.WithoutSizeLimit()) // a client that has not written yet
		writer := NewWriter(1, c.dest, buf.Discard, protocol.TransferTypeStream, [8]byte{}, nil)
		start := time.Now()
		if err := writeFirstPayload(c.ctx, reader, writer, c.dest); err != nil {
			t.Fatal(err)
		}
		if waited := time.Since(start) >= 90*time.Millisecond; waited != c.wait {
			t.Errorf("%v: waited %v, want a wait: %v", c.dest, time.Since(start), c.wait)
		}
	}
}
