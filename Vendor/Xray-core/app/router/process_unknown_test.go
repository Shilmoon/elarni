package router

import (
	"testing"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

// A flow whose owner the lookup could not find may belong to a listed app. The rule "-1",
// Android's name for such an owner, matches it on every platform, so "Only listed" can keep
// it in the tunnel. A flow from another host has no owner here and does not match.
func TestUnknownOwnerRuleMatchesAFailedLookup(t *testing.T) {
	previous := lookupProcess
	t.Cleanup(func() { lookupProcess = previous })
	route := func(result error, names ...string) bool {
		lookupProcess = func(string, string, uint16, string, uint16) (int, string, string, error) {
			if result != nil {
				return 0, "", "", result
			}
			return 4242, "browser", "/apps/browser", nil
		}
		return NewProcessNameMatcher(names).Apply(&routingsession.Context{
			Inbound:  &session.Inbound{Source: net.TCPDestination(net.LocalHostIP, 50000)},
			Outbound: &session.Outbound{Target: net.TCPDestination(net.ParseAddress("1.2.3.10"), 443)},
		})
	}
	failed := errors.New("connection for 127.0.0.1:50000 not found")
	for _, c := range []struct {
		name   string
		result error
		names  []string
		want   bool
	}{
		{"failed lookup, unknown rule", failed, []string{"telegram", "-1"}, true},
		{"failed lookup, no unknown rule", failed, []string{"telegram"}, false},
		{"another host", net.ErrNotLocal, []string{"-1"}, false},
		{"found owner, unknown rule", nil, []string{"-1"}, false},
		{"found owner, listed", nil, []string{"-1", "browser"}, true},
	} {
		if got := route(c.result, c.names...); got != c.want {
			t.Errorf("%s: matched %v, want %v", c.name, got, c.want)
		}
	}
}
