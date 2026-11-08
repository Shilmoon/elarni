package share

import (
	"net/netip"
	"testing"
)

func TestWindowsRoutesRespectBothFamiliesAndExclusions(t *testing.T) {
	policy := &WindowsRoutePolicy{IncludedRoutes: []string{"10.0.0.0/8", "2001:db8::/32"},
		ExcludedRoutes: []string{"10.1.0.0/16", "2001:db8:1::/48"}, EnforceRoutes: true}
	routes, err := WindowsRoutes(policy)
	if err != nil {
		t.Fatal(err)
	}
	contains := func(ip string) bool {
		for _, p := range routes {
			if p.Contains(netip.MustParseAddr(ip)) {
				return true
			}
		}
		return false
	}
	for ip, want := range map[string]bool{"10.2.3.4": true, "10.1.2.3": false, "11.0.0.1": false,
		"2001:db8:2::1": true, "2001:db8:1::1": false, "2001:db9::1": false} {
		if contains(ip) != want {
			t.Fatalf("route membership wrong for %s", ip)
		}
	}
	policy.EnforceRoutes = false
	policy.IncludeAllNetworks = true
	routes, err = WindowsRoutes(policy)
	if err != nil || !contains("11.0.0.1") || contains("10.1.2.3") {
		t.Fatal("full capture lost exclusions")
	}
	guard, err := WindowsProtectedRoutes(policy)
	if err != nil || len(guard) == 0 {
		t.Fatal("route guard missing")
	}
	for _, p := range guard {
		if p.Contains(netip.MustParseAddr("127.0.0.1")) || p.Contains(netip.MustParseAddr("::1")) {
			t.Fatal("loopback blocked")
		}
	}
	policy.EnforceRoutes = true
	if _, err := WindowsRoutes(policy); err == nil {
		t.Fatal("incompatible enforcement accepted")
	}
	policy.IncludeAllNetworks = false
	policy.IncludedRoutes = []string{"0.0.0.0/0"}
	if _, err := WindowsRoutes(policy); err == nil {
		t.Fatal("default enforcement accepted")
	}
	policy.EnforceRoutes = false
	policy.IncludedRoutes = []string{"10.1.2.3/8"}
	if _, err := WindowsRoutes(policy); err == nil {
		t.Fatal("noncanonical privileged route accepted")
	}
}

// Regression: included routes were merged into one set, so a host listed next to
// a default route became part of a /1, and a longer physical route (a LAN /24)
// carried that host outside the tunnel.
func TestWindowsRoutesKeepEachIncludedPrefix(t *testing.T) {
	routes, err := WindowsRoutes(&WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0", "198.18.77.2/32", "10.1.2.3/32"},
		ExcludedRoutes: []string{"10.1.0.0/16"}, IncludeAllNetworks: true})
	if err != nil {
		t.Fatal(err)
	}
	got := map[netip.Prefix]bool{}
	for _, p := range routes {
		if got[p] {
			t.Fatalf("duplicate route %s in %v", p, routes)
		}
		got[p] = true
		if p.Contains(netip.MustParseAddr("10.1.2.3")) {
			t.Fatalf("excluded host routed by %s", p)
		}
	}
	if !got[netip.MustParsePrefix("198.18.77.2/32")] || !got[netip.MustParsePrefix("::/1")] {
		t.Fatalf("routes %v lost an included prefix", routes)
	}
}

// Block traffic without VPN guards every route outside the tunnel, so it cannot
// be combined with enforcing specific routes.
func TestWindowsBlockWithoutVPNGuardsEveryRoute(t *testing.T) {
	policy := &WindowsRoutePolicy{IncludedRoutes: []string{"10.0.0.0/8"}, BlockWithoutVPN: true}
	guard, err := WindowsProtectedRoutes(policy)
	if err != nil {
		t.Fatal(err)
	}
	covered := func(ip string) bool {
		for _, p := range guard {
			if p.Contains(netip.MustParseAddr(ip)) {
				return true
			}
		}
		return false
	}
	if !covered("11.0.0.1") || !covered("2001:db9::1") || covered("127.0.0.1") || covered("fe80::1") {
		t.Fatalf("the block guards %v", guard)
	}
	policy.EnforceRoutes = true
	if _, err := WindowsRoutes(policy); err == nil {
		t.Fatal("enforced specific routes accepted beside the block")
	}
}

// Elarni: LAN discovery (mDNS, SSDP, LLMNR, WS-Discovery, DHCP-style broadcast) stays on the
// physical network, where its replies come from; routed into the tunnel it reached no device
// and filled the UDP session table. Block traffic without VPN keeps everything in the tunnel.
func TestWindowsRoutesLeaveDiscoveryOnTheLocalNetwork(t *testing.T) {
	covered := func(routes []netip.Prefix, ip string) bool {
		for _, p := range routes {
			if p.Contains(netip.MustParseAddr(ip)) {
				return true
			}
		}
		return false
	}
	discovery := []string{"224.0.0.251", "239.255.255.250", "224.0.0.252", "255.255.255.255", "ff02::fb", "ff02::c", "ff05::1:3"}
	unicast := []string{"8.8.8.8", "223.255.255.255", "240.0.0.1", "255.255.255.254", "2001:db8::1", "fe80::1", "feff::1"}
	for _, policy := range []*WindowsRoutePolicy{nil, {IncludedRoutes: []string{"0.0.0.0/0", "::/0"}},
		{IncludedRoutes: []string{"10.0.0.0/8"}, IncludeAllNetworks: true}, {IncludedRoutes: []string{"224.0.0.0/4", "ff00::/8", "8.8.8.8/32"}}} {
		routes, err := WindowsRoutes(policy)
		if err != nil {
			t.Fatal(err)
		}
		for _, ip := range discovery {
			if covered(routes, ip) {
				t.Fatalf("policy %+v routes discovery address %s into the tunnel: %v", policy, ip, routes)
			}
		}
		if policy != nil && !policy.IncludeAllNetworks && len(policy.IncludedRoutes) == 3 {
			continue // only 8.8.8.8 is left of that list
		}
		for _, ip := range unicast {
			if !covered(routes, ip) {
				t.Fatalf("policy %+v lost %s: %v", policy, ip, routes)
			}
		}
	}
	routes, err := WindowsRoutes(&WindowsRoutePolicy{IncludedRoutes: []string{"10.0.0.0/8"}, BlockWithoutVPN: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, ip := range append(discovery, unicast...) {
		if !covered(routes, ip) {
			t.Fatalf("block traffic without VPN leaves %s outside the tunnel: %v", ip, routes)
		}
	}
}
