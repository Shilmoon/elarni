//go:build windows

package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// No packets are sent: exercise the real Windows binding operation before bind.
func TestPhysicalBindingRefreshesRemovedInterface(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	var loopback uint32
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 {
			loopback = uint32(iface.Index)
			break
		}
	}
	if loopback == 0 {
		t.Fatal("loopback interface missing")
	}
	luid, err := winipcfg.LUIDFromIndex(loopback)
	if err != nil {
		t.Fatal(err)
	}
	loads := 0
	cache := &physicalNetworkCache{load: func() (*physicalNetworkSnapshot, error) {
		loads++
		return &physicalNetworkSnapshot{routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: loopback, luid: luid}}}, nil
	}}
	cache.snapshot.Store(&physicalNetworkSnapshot{captured: time.Now(), routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 0x7ffffffe}}})
	lc := net.ListenConfig{Control: func(network, _ string, raw syscall.RawConn) error {
		return cache.bind(network, "192.0.2.1:53", raw)
	}}
	conn, err := lc.ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("stale interface did not recover:", err)
	}
	conn.Close()
	if loads != 1 {
		t.Fatalf("refresh count = %d, want one retry", loads)
	}
}

func TestPhysicalNetworkRefreshInvalidatesRoutesAndDNS(t *testing.T) {
	firstDNS, secondDNS := &net.Resolver{}, &net.Resolver{}
	current := &physicalNetworkSnapshot{dns: firstDNS, routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 1}}}
	var loadErr error
	loads := 0
	cache := &physicalNetworkCache{load: func() (*physicalNetworkSnapshot, error) { loads++; return current, loadErr }}
	// A stale good snapshot is served while one refresh runs beside the dial.
	refreshed := func(stale *physicalNetworkSnapshot) (*physicalNetworkSnapshot, error) {
		if got, err := cache.get(false); err != nil || got != stale {
			t.Fatal("a dial waited for the refresh", err)
		}
		for cache.refreshing.Load() {
			time.Sleep(time.Millisecond)
		}
		return cache.get(false)
	}
	first, err := cache.get(false)
	if err != nil || first.dns != firstDNS {
		t.Fatal("initial snapshot failed", err)
	}
	if _, err := cache.get(false); err != nil || loads != 1 {
		t.Fatal("unchanged snapshot was re-enumerated")
	}
	current = &physicalNetworkSnapshot{dns: secondDNS, routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 2}}}
	cache.dirty.Store(true)
	second, err := refreshed(first)
	if err != nil || second.routes[0].index != 2 || second.dns != secondDNS || first.routes[0].index != 1 {
		t.Fatal("network change did not atomically replace routes and DNS", err)
	}
	// DNS-only edits also expire without depending on an interface notification.
	expired := &physicalNetworkSnapshot{captured: time.Now().Add(-time.Minute), dns: firstDNS}
	cache.snapshot.Store(expired)
	if got, err := refreshed(expired); err != nil || got.dns != secondDNS {
		t.Fatal("expired DNS snapshot retained", err)
	}
	loadErr = errors.New("fixture enumeration failed")
	cache.dirty.Store(true)
	if _, err := refreshed(cache.snapshot.Load()); err == nil {
		t.Fatal("failed refresh reused stale routes")
	}
	before := loads
	if _, err := cache.get(false); err == nil || loads != before {
		t.Fatal("failed enumeration must be cached until invalidated or expired")
	}
}

// Regression: after every route or interface notification (the tunnel's own too),
// and every 5 s, the first dial enumerated the network while all others waited.
func TestPhysicalNetworkDialsDoNotWaitForARefresh(t *testing.T) {
	release := make(chan struct{})
	var loads atomic.Int32
	cache := &physicalNetworkCache{load: func() (*physicalNetworkSnapshot, error) {
		loads.Add(1)
		<-release
		return &physicalNetworkSnapshot{routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 2}}}, nil
	}}
	stale := &physicalNetworkSnapshot{captured: time.Now(), routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 1}}}
	cache.snapshot.Store(stale)
	cache.dirty.Store(true)
	served := make(chan *physicalNetworkSnapshot, 8)
	for range 8 {
		go func() { s, _ := cache.get(false); served <- s }()
	}
	for range 8 {
		select {
		case s := <-served:
			if s != stale {
				t.Fatal("dial was not served the last snapshot")
			}
		case <-time.After(5 * time.Second):
			t.Fatal("a dial waited for the enumeration")
		}
	}
	close(release)
	for cache.refreshing.Load() {
		time.Sleep(time.Millisecond)
	}
	if s, err := cache.get(false); err != nil || s.routes[0].index != 2 || loads.Load() != 1 {
		t.Fatalf("refresh result %v, %d enumerations; want one", err, loads.Load())
	}
}

// After a sleep, sockets on the same interface may be dead too.
func TestResumeReopensSocketsOnUnchangedRoutes(t *testing.T) {
	cache := &physicalNetworkCache{wake: make(chan struct{}, 1), load: func() (*physicalNetworkSnapshot, error) {
		return &physicalNetworkSnapshot{routes: []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 7}}}, nil
	}}
	defer close(cache.wake)
	moved := make(chan struct{}, 4)
	go cache.watchDefaults(cache.defaults(), 0, func() { moved <- struct{}{} })
	cache.resume()
	select {
	case <-moved:
	case <-time.After(5 * time.Second):
		t.Fatal("resume did not reopen sockets")
	}
}

func TestPhysicalRouteSelectionPreservesPrefixMetricAndZone(t *testing.T) {
	routes := []physicalRoute{
		{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 1, metric: 1},
		{prefix: netip.MustParsePrefix("192.0.2.0/24"), index: 2, metric: 20},
		{prefix: netip.MustParsePrefix("192.0.2.0/24"), index: 3, metric: 10},
		{prefix: netip.MustParsePrefix("fe80::/64"), index: 4, metric: 1},
		{prefix: netip.MustParsePrefix("fe80::/64"), index: 5, metric: 10},
	}
	for address, want := range map[string]uint32{"192.0.2.7": 3, "198.51.100.7": 1, "fe80::7%5": 5, "2001:db8::7": 0} {
		got := selectPhysicalRoute(routes, netip.MustParseAddr(address))
		if want == 0 && got != nil || want != 0 && (got == nil || got.index != want) {
			t.Errorf("route for %s = %v, want interface %d", address, got, want)
		}
	}
}

// Regression: WireGuard kept its socket on the adapter that carried the default
// route when it started, so a move to another adapter left the tunnel dead.
func TestPhysicalDefaultRouteMoveReopensSockets(t *testing.T) {
	var mu sync.Mutex
	routes := []physicalRoute{{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 7}}
	cache := &physicalNetworkCache{wake: make(chan struct{}, 1), load: func() (*physicalNetworkSnapshot, error) {
		mu.Lock()
		defer mu.Unlock()
		return &physicalNetworkSnapshot{routes: routes}, nil
	}}
	defer close(cache.wake)
	set := func(next ...physicalRoute) {
		mu.Lock()
		routes = next
		mu.Unlock()
		cache.invalidate()
	}
	start := cache.defaults()
	set(physicalRoute{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 7}, physicalRoute{prefix: netip.MustParsePrefix("192.168.1.0/24"), index: 9})
	if cache.defaults() != start {
		t.Fatal("a LAN route moved the default route")
	}
	moved := make(chan struct{}, 4)
	go cache.watchDefaults(start, 0, func() { moved <- struct{}{} })
	set(physicalRoute{prefix: netip.MustParsePrefix("0.0.0.0/0"), index: 9})
	select {
	case <-moved:
	case <-time.After(5 * time.Second):
		t.Fatal("moving the default route did not reopen sockets")
	}
}

// The tunnel's helper resets a connection that runs outside the tunnel only when Windows now
// routes its destination into the tunnel. Asked of the loopback interface here: no route is added.
func TestRoutedIntoFollowsTheSystemsBestRoute(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	var loopback winipcfg.LUID
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 {
			if loopback, err = winipcfg.LUIDFromIndex(uint32(iface.Index)); err != nil {
				t.Fatal(err)
			}
			break
		}
	}
	if loopback == 0 {
		t.Fatal("loopback interface missing")
	}
	routed := routedInto(loopback)
	for address, want := range map[string]bool{
		"127.0.0.1":        true,
		"::1":              true,
		"::ffff:127.0.0.1": true,
		// Documentation addresses: the default route's interface, or none.
		"192.0.2.1":   false,
		"2001:db8::1": false,
	} {
		if got := routed(netip.MustParseAddr(address)); got != want {
			t.Errorf("%s: routed into the loopback interface %t, want %t", address, got, want)
		}
	}
	if routedInto(loopback + 1)(netip.MustParseAddr("127.0.0.1")) {
		t.Error("127.0.0.1 is routed into another interface")
	}
}
