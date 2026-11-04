package loopback

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
)

type contentDispatcher struct {
	routing.Dispatcher
	content *session.Content
}

func (d *contentDispatcher) DispatchLink(ctx context.Context, _ net.Destination, _ *transport.Link) error {
	d.content = session.ContentFromContext(ctx)
	return nil
}

// Elarni: per-app and routing configs reach the proxy through this loopback. Without the first
// pass's silent-client mark, a server-first protocol on an unlisted port waited 500 ms more.
func TestSecondPassKeepsTheSilentClientMark(t *testing.T) {
	for _, silent := range []bool{true, false} {
		dispatcher := &contentDispatcher{}
		l := &Loopback{inboundTag: "provider", dispatcherInstance: dispatcher}
		target := net.TCPDestination(net.DomainAddress("mail.example"), 2525)
		ctx := session.ContextWithOutbounds(context.Background(), []*session.Outbound{{Target: target}})
		ctx = session.ContextWithContent(ctx, &session.Content{ClientSilent: silent})
		if err := l.Process(ctx, &transport.Link{}, nil); err != nil {
			t.Fatal(err)
		}
		if dispatcher.content == nil || dispatcher.content.ClientSilent != silent {
			t.Fatalf("second pass ClientSilent = %v, want %v", dispatcher.content != nil && dispatcher.content.ClientSilent, silent)
		}
	}
}
