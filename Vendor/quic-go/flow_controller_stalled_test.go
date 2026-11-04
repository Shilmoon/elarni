package quic

import (
	"testing"

	"github.com/apernet/quic-go/internal/monotime"
	"github.com/apernet/quic-go/internal/protocol"
	"github.com/apernet/quic-go/internal/utils"
)

// Elarni: bytes held unread by streams the application stopped reading counted against the
// connection window, so three stalled downloads froze every stream of the connection.
func TestConnectionWindowMovesPastStalledStreams(t *testing.T) {
	const window, maxWindow = 15 << 20, 20 << 20
	fc := newConnectionFlowController(window, maxWindow, func(protocol.ByteCount) bool { return true }, utils.NewRTTStats(), utils.DefaultLogger)
	now := monotime.Now()
	if err := fc.IncrementHighestReceived(14<<20, now); err != nil { // stalled streams, never read
		t.Fatal(err)
	}
	offset := fc.GetWindowUpdate(now)
	if offset < 14<<20+window {
		t.Fatalf("window update to %d leaves under one window past %d unread bytes", offset, 14<<20)
	}
	// The allowance is bounded: unread bytes beyond it hold the window as before.
	for fc.IncrementHighestReceived(fc.receiveWindow-fc.highestReceived, now) == nil && fc.highestReceived < 10*maxWindow {
		if fc.GetWindowUpdate(now) == 0 {
			break
		}
	}
	if limit := protocol.ByteCount(2*maxWindow + window); fc.receiveWindow > limit {
		t.Fatalf("unread bytes reached a window of %d, want at most %d", fc.receiveWindow, limit)
	}
	if fc.GetWindowUpdate(now) != 0 {
		t.Fatal("window still moved once the allowance was held")
	}
}
