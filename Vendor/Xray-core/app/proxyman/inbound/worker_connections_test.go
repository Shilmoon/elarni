package inbound

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/transport/internet/stat"
)

func TestWorkerConnectionsCloseAcceptedAndRejectLateCallbacks(t *testing.T) {
	var connections workerConnections
	accepted, peer := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	if !connections.add(stat.Connection(accepted), cancel) {
		t.Fatal("running worker rejected a connection")
	}
	connections.close()
	if ctx.Err() == nil {
		t.Fatal("processing context survived Close")
	}
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := peer.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("accepted connection left open: %v", err)
	}
	late, _ := net.Pipe()
	if connections.add(stat.Connection(late), func() {}) {
		t.Fatal("callback racing Close was accepted")
	}
	connections.start()
	if !connections.add(stat.Connection(late), func() {}) {
		t.Fatal("restarted worker rejected a connection")
	}
	connections.remove(stat.Connection(late))
}
