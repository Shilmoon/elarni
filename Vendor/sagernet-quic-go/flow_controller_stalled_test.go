package quic

import (
	"runtime"
	"testing"

	"github.com/sagernet/quic-go/internal/monotime"
	"github.com/sagernet/quic-go/internal/protocol"
	"github.com/sagernet/quic-go/internal/utils"
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
	if limit := unreadAllowance(runtime.GOOS, maxWindow) + window; fc.receiveWindow > limit {
		t.Fatalf("unread bytes reached a window of %d, want at most %d", fc.receiveWindow, limit)
	}
	if fc.GetWindowUpdate(now) != 0 {
		t.Fatal("window still moved once the allowance was held")
	}
}

// iOS kills the packet tunnel above about 50 MB; one connection's unread bytes must stay well under it there.
func TestUnreadAllowanceIsSmallerOnIOS(t *testing.T) {
	const maxWindow = 16 << 20 // TUIC's connection window
	if got := unreadAllowance("ios", maxWindow) + maxWindow; got > 3*maxWindow/2 {
		t.Fatalf("an iOS connection may hold %d unread bytes, want at most %d", got, 3*maxWindow/2)
	}
	if got := unreadAllowance("android", maxWindow); got != 2*maxWindow {
		t.Fatalf("the allowance elsewhere changed to %d", got)
	}
}
