package tun

import (
	"net/netip"
	"slices"
	"testing"
)

// Elarni: a tunnel whose routes leave discovery out must also demote the routes to it Windows gives
// the TUN interface; one whose routes take everything (Block traffic without VPN) needs its own,
// as its split routes are shorter than every interface's discovery routes.
func TestSplitDiscoveryFollowsTheRoutes(t *testing.T) {
	parse := func(values ...string) []netip.Prefix {
		var prefixes []netip.Prefix
		for _, value := range values {
			prefixes = append(prefixes, netip.MustParsePrefix(value))
		}
		return prefixes
	}
	for _, c := range []struct {
		name   string
		routes []netip.Prefix
		left   []netip.Prefix
		taken  []netip.Prefix
	}{
		{"everything", parse("0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"), nil, discoveryPrefixes},
		{"all but discovery", parse("0.0.0.0/1", "128.0.0.0/2", "192.0.0.0/3", "240.0.0.0/5", "255.255.255.254/32", "::/1", "8000::/2", "fe00::/8"), discoveryPrefixes, nil},
		{"one multicast group only", parse("224.0.0.251/32", "10.0.0.0/8"), discoveryPrefixes, nil},
		{"IPv4 only", parse("0.0.0.0/0"), parse("ff00::/8"), parse("224.0.0.0/4", "255.255.255.255/32")},
		{"none", nil, discoveryPrefixes, nil},
	} {
		left, taken := splitDiscovery(c.routes)
		if !slices.Equal(left, c.left) || !slices.Equal(taken, c.taken) {
			t.Errorf("%s: left out %v and took %v, want %v and %v", c.name, left, taken, c.left, c.taken)
		}
	}
}
