package tun

import "net/netip"

// discoveryPrefixes are the destinations of LAN discovery: IPv4 multicast (mDNS, SSDP, LLMNR,
// WS-Discovery), the limited broadcast and IPv6 multicast (Elarni).
var discoveryPrefixes = []netip.Prefix{
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("255.255.255.255/32"),
	netip.MustParsePrefix("ff00::/8"),
}

// splitDiscovery sorts the discovery prefixes into those no route of the tunnel covers and those
// its routes take. Windows gives every interface its own routes to them, longer than a tunnel's
// split routes: the tunnel's own, which its metric 0 makes win, have to lose for discovery left
// to the physical network, and have to exist for discovery the tunnel takes (Elarni).
func splitDiscovery(routes []netip.Prefix) (left, taken []netip.Prefix) {
	for _, discovery := range discoveryPrefixes {
		covered := false
		for _, route := range routes {
			if route.Bits() <= discovery.Bits() && route.Contains(discovery.Addr()) {
				covered = true
				break
			}
		}
		if covered {
			taken = append(taken, discovery)
		} else {
			left = append(left, discovery)
		}
	}
	return left, taken
}
