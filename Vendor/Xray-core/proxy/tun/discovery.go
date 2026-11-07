package tun

import "net/netip"

// discoveryPrefixes are the destinations of LAN discovery: IPv4 multicast (mDNS, SSDP, LLMNR,
// WS-Discovery), the limited broadcast and IPv6 multicast (Elarni).
var discoveryPrefixes = []netip.Prefix{
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("255.255.255.255/32"),
	netip.MustParsePrefix("ff00::/8"),
}

// discoveryLeftOut lists the discovery prefixes that no route of the tunnel covers. Windows gives
// every interface its own routes to them, so the tunnel's, which its metric 0 would make win, have
// to lose for discovery to stay on the physical network the routes leave it to (Elarni).
func discoveryLeftOut(routes []netip.Prefix) []netip.Prefix {
	var left []netip.Prefix
	for _, discovery := range discoveryPrefixes {
		covered := false
		for _, route := range routes {
			if route.Bits() <= discovery.Bits() && route.Contains(discovery.Addr()) {
				covered = true
				break
			}
		}
		if !covered {
			left = append(left, discovery)
		}
	}
	return left
}
