package dispatcher

import (
	"context"
	"errors"
	"testing"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	routing_session "github.com/xtls/xray-core/features/routing/session"
	"github.com/xtls/xray-core/transport"
)

type recentHandler struct {
	tag    string
	config *serial.TypedMessage
}

func (h recentHandler) Start() error                              { return nil }
func (h recentHandler) Close() error                              { return nil }
func (h recentHandler) Tag() string                               { return h.tag }
func (h recentHandler) Dispatch(context.Context, *transport.Link) {}
func (h recentHandler) SenderSettings() *serial.TypedMessage      { return nil }
func (h recentHandler) ProxySettings() *serial.TypedMessage       { return h.config }

func appContext(port net.Port, find func() (int, string, string, error)) *routing_session.Context {
	link := &routing_session.Context{
		Inbound:  &session.Inbound{Tag: "elarni-tun", Source: net.TCPDestination(net.LocalHostIP, port)},
		Outbound: &session.Outbound{Target: net.TCPDestination(net.DomainAddress("example.com"), 443)},
	}
	if find != nil {
		link.LookupProcess(find)
	}
	return link
}

// A per-app rule that follows normal routing sends the connection through a loopback outbound
// and routes it again; the list shows it once, with the app the first decision found and the
// outbound the last one chose.
func TestRecentConnectionsJoinARoutedAgainConnection(t *testing.T) {
	var recent recentConnections
	recent.reset()
	reentry := recentHandler{"elarni-apps-0", &serial.TypedMessage{Type: "xray.proxy.loopback.Config"}}
	direct := recentHandler{"elarni-direct", &serial.TypedMessage{Type: "xray.proxy.freedom.Config"}}
	block := recentHandler{"elarni-block", &serial.TypedMessage{Type: "xray.proxy.blackhole.Config"}}
	proxy := recentHandler{"elarni-proxy", nil}
	destination := net.TCPDestination(net.ParseAddress("192.0.2.1"), 443)

	found := appContext(50000, func() (int, string, string, error) { return 42, "claude", "/opt/claude/claude", nil })
	found.NoteProcessAncestor("/opt/claude/launcher")
	recent.record(7, found, destination, reentry, "elarni-per-app-listed")
	recent.record(7, appContext(50000, nil), destination, proxy, "")
	recent.record(8, appContext(50001, func() (int, string, string, error) { return 0, "", "", errors.New("not found") }), destination, block, "elarni-per-app-other")
	recent.record(9, appContext(50002, nil), destination, direct, "")
	// The core's own traffic has no source.
	recent.record(10, &routing_session.Context{Inbound: &session.Inbound{Tag: "elarni-dns-client"}}, destination, direct, "")

	dispatcher := &DefaultDispatcher{}
	dispatcher.recent.epoch, dispatcher.recent.seq, dispatcher.recent.entries = recent.epoch, recent.seq, recent.entries
	epoch, seq, entries := dispatcher.RecentConnections(0)
	if epoch == 0 || seq != 4 || len(entries) != 3 {
		t.Fatalf("epoch %d seq %d entries %+v", epoch, seq, entries)
	}
	joined := entries[0]
	if joined.Key != 1 || joined.Seq != 2 || joined.Owner != "found" || joined.PID != 42 || joined.Path != "/opt/claude/claude" ||
		joined.Outbound != "elarni-proxy" || joined.Kind != "proxy" || joined.Host != "example.com" || joined.Port != 443 ||
		joined.Network != "tcp" || len(joined.Rules) != 1 || joined.Rules[0] != "elarni-per-app-listed" ||
		joined.Via != "/opt/claude/launcher" {
		t.Fatalf("joined %+v", joined)
	}
	if unknown := entries[1]; unknown.Owner != "unknown" || unknown.Kind != "block" || unknown.Name != "" {
		t.Fatalf("unknown owner %+v", unknown)
	}
	if unchecked := entries[2]; unchecked.Owner != "" || unchecked.Kind != "direct" || unchecked.Rules != nil {
		t.Fatalf("no lookup %+v", unchecked)
	}
	if _, _, later := dispatcher.RecentConnections(seq); len(later) != 0 {
		t.Fatalf("nothing changed after %d: %+v", seq, later)
	}
}

// The list keeps the newest connections; a connection routed again after older ones were
// dropped still finds its entry, and dropped ones stop waiting.
func TestRecentConnectionsKeepTheNewest(t *testing.T) {
	var recent recentConnections
	recent.reset()
	reentry := recentHandler{"elarni-apps-0", &serial.TypedMessage{Type: "xray.proxy.loopback.Config"}}
	direct := recentHandler{"elarni-direct", &serial.TypedMessage{Type: "xray.proxy.freedom.Config"}}
	destination := net.UDPDestination(net.ParseAddress("192.0.2.1"), 53)
	const total = recentCapacity*2 + 17
	for id := uint32(1); id <= total; id++ {
		recent.record(id, appContext(net.Port(id), nil), destination, reentry, "")
	}
	if len(recent.entries) != recentCapacity || len(recent.reentered) != recentCapacity {
		t.Fatalf("%d entries, %d wait to be routed again", len(recent.entries), len(recent.reentered))
	}
	dispatcher := &DefaultDispatcher{}
	read := func() []RecentConnection {
		dispatcher.recent.entries, dispatcher.recent.seq = recent.entries, recent.seq
		_, _, entries := dispatcher.RecentConnections(0)
		return entries
	}
	// The oldest kept connection and the newest, routed again.
	oldest := uint32(total - recentCapacity + 1)
	recent.record(oldest, appContext(net.Port(oldest), nil), destination, direct, "")
	recent.record(total, appContext(net.Port(total), nil), destination, direct, "")
	entries := read()
	if len(entries) != recentCapacity {
		t.Fatalf("%d entries", len(entries))
	}
	for i, key := range []uint64{uint64(oldest), total} {
		if got := entries[len(entries)-2+i]; got.Key != key || got.Kind != "direct" || got.Network != "udp" {
			t.Fatalf("routed again %d: %+v", key, got)
		}
	}
	// A dropped connection starts a new entry, which drops the oldest.
	recent.record(1, appContext(1, nil), destination, direct, "")
	entries = read()
	if newest := entries[len(entries)-1]; len(entries) != recentCapacity || newest.Key != total+1 || newest.Kind != "direct" {
		t.Fatalf("%d entries, newest %+v", len(entries), newest)
	}
	for _, entry := range entries {
		if entry.Key == uint64(oldest) {
			t.Fatalf("the oldest stayed: %+v", entry)
		}
	}
	if len(recent.reentered) != recentCapacity-2 {
		t.Fatalf("%d wait to be routed again", len(recent.reentered))
	}
}
