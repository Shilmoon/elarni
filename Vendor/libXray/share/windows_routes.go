package share

import (
	"errors"
	"go4.org/netipx"
	"net/netip"
)

type WindowsRoutePolicy struct {
	IncludedRoutes     []string `json:"includedRoutes"`
	ExcludedRoutes     []string `json:"excludedRoutes"`
	IncludeAllNetworks bool     `json:"includeAllNetworks"`
	EnforceRoutes      bool     `json:"enforceRoutes"`
	HideVPNIcon        bool     `json:"hideVPNIcon"`
	// BlockWithoutVPN captures every route and keeps the guard after an unexpected exit.
	BlockWithoutVPN bool `json:"blockWithoutVPN"`
}

// DiscoveryPrefixes are the destinations of LAN discovery: IPv4 multicast (mDNS, SSDP,
// LLMNR, WS-Discovery), the limited broadcast and IPv6 multicast. Routed into the tunnel, they
// reach no device, so unless Block traffic without VPN keeps everything inside, the tunnel
// leaves them to the physical network (Elarni).
var DiscoveryPrefixes = []netip.Prefix{
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("255.255.255.255/32"),
	netip.MustParsePrefix("ff00::/8"),
}

// WindowsRoutes derives only routes owned by the disposable tunnel adapter.
func WindowsRoutes(policy *WindowsRoutePolicy) ([]netip.Prefix, error) {
	if policy == nil {
		policy = &WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0", "::/0"}}
	}
	invalid := errors.New("invalid_routes")
	if len(policy.IncludedRoutes) == 0 || len(policy.IncludedRoutes) > 64 || len(policy.ExcludedRoutes) > 64 ||
		policy.EnforceRoutes && (policy.IncludeAllNetworks || policy.BlockWithoutVPN) {
		return nil, invalid
	}
	included := []netip.Prefix{}
	for _, value := range policy.IncludedRoutes {
		p, err := netip.ParsePrefix(value)
		if err != nil || p != p.Masked() || p.Addr().Is4In6() || policy.EnforceRoutes && p.Bits() == 0 {
			return nil, invalid
		}
		included = append(included, p)
	}
	if policy.IncludeAllNetworks || policy.BlockWithoutVPN {
		included = append(included, netip.MustParsePrefix("0.0.0.0/0"), netip.MustParsePrefix("::/0"))
	}
	excluded := append([]string{}, policy.ExcludedRoutes...)
	if !policy.BlockWithoutVPN {
		// Elarni: LAN discovery stays on the physical network, where its replies come from.
		for _, p := range DiscoveryPrefixes {
			excluded = append(excluded, p.String())
		}
	}
	if policy.HideVPNIcon {
		excluded = append(excluded, "0.0.0.0/8", "::/128")
	}
	var exclusions netipx.IPSetBuilder
	for _, value := range excluded {
		p, err := netip.ParsePrefix(value)
		if err != nil || p != p.Masked() || p.Addr().Is4In6() {
			return nil, invalid
		}
		exclusions.AddPrefix(p)
	}
	removed, err := exclusions.IPSet()
	if err != nil {
		return nil, invalid
	}
	// Routes stay apart rather than merged: a host listed beside a default
	// must keep its own prefix to outrank a longer physical route.
	routes := []netip.Prefix{}
	seen := map[netip.Prefix]bool{}
	for _, p := range included {
		var set netipx.IPSetBuilder
		set.AddPrefix(p)
		set.RemoveSet(removed)
		result, err := set.IPSet()
		if err != nil {
			return nil, invalid
		}
		for _, p := range result.Prefixes() {
			split := []netip.Prefix{p}
			// Split defaults to outrank a physical default without deleting it.
			if p.Bits() == 0 && p.Addr().Is4() {
				split = []netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("128.0.0.0/1")}
			} else if p.Bits() == 0 {
				split = []netip.Prefix{netip.MustParsePrefix("::/1"), netip.MustParsePrefix("8000::/1")}
			}
			for _, p := range split {
				if !seen[p] {
					seen[p] = true
					routes = append(routes, p)
				}
			}
		}
	}
	if len(routes) == 0 || len(routes) > 8192 {
		return nil, invalid
	}
	return routes, nil
}

// Route enforcement leaves local control protocols usable on the physical link.
func WindowsProtectedRoutes(policy *WindowsRoutePolicy) ([]netip.Prefix, error) {
	routes, err := WindowsRoutes(policy)
	if err != nil {
		return nil, err
	}
	if policy == nil || !policy.EnforceRoutes && !policy.IncludeAllNetworks && !policy.BlockWithoutVPN {
		return nil, nil
	}
	return ProtectedPrefixes(routes)
}

// ProtectedPrefixes removes local, link-local and multicast ranges, which never
// leave through a tunnel, from routes the guard rejects outside it.
func ProtectedPrefixes(routes []netip.Prefix) ([]netip.Prefix, error) {
	var set netipx.IPSetBuilder
	for _, p := range routes {
		set.AddPrefix(p)
	}
	for _, value := range []string{"127.0.0.0/8", "::1/128", "169.254.0.0/16", "fe80::/10", "224.0.0.0/4", "ff00::/8", "255.255.255.255/32"} {
		set.RemovePrefix(netip.MustParsePrefix(value))
	}
	result, err := set.IPSet()
	if err != nil {
		return nil, err
	}
	return result.Prefixes(), nil
}
