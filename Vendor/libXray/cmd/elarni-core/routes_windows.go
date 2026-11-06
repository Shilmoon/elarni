//go:build windows

package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/common/flightrecorder"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

type physicalRoute struct {
	prefix netip.Prefix
	index  uint32
	metric uint64
	luid   winipcfg.LUID
}

type physicalNetworkSnapshot struct {
	routes   []physicalRoute
	dns      *net.Resolver
	captured time.Time
	err      error
}

type physicalNetworkCache struct {
	mu         sync.Mutex
	snapshot   atomic.Pointer[physicalNetworkSnapshot]
	dirty      atomic.Bool
	refreshing atomic.Bool
	resumed    atomic.Bool
	load       func() (*physicalNetworkSnapshot, error)
	wake       chan struct{}
}

var physicalNetwork physicalNetworkCache
var physicalBindingsOnce sync.Once

func (c *physicalNetworkCache) fresh(s *physicalNetworkSnapshot) bool {
	// DNS-only edits need not generate a route/interface notification.
	return s != nil && time.Since(s.captured) < 5*time.Second && !c.dirty.Load()
}

func (c *physicalNetworkCache) get(force bool) (*physicalNetworkSnapshot, error) {
	s := c.snapshot.Load()
	if !force && s != nil && s.err == nil {
		// Dials keep the last good snapshot while one refresh runs beside them, instead
		// of all waiting behind the enumeration. bind still checks the chosen interface
		// and refreshes in line when it is gone.
		if !c.fresh(s) && c.refreshing.CompareAndSwap(false, true) {
			go func() {
				defer c.refreshing.Store(false)
				_, _ = c.refresh(false)
			}()
		}
		return s, nil
	}
	return c.refresh(force)
}

func (c *physicalNetworkCache) refresh(force bool) (*physicalNetworkSnapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if s := c.snapshot.Load(); !force && c.fresh(s) {
		return s, s.err
	}
	// Preserve notifications that arrive during enumeration for the next lookup.
	c.dirty.Store(false)
	load := c.load
	if load == nil {
		load = func() (*physicalNetworkSnapshot, error) { return readPhysicalNetwork(c.bind) }
	}
	s, err := load()
	if err != nil || s == nil {
		s = &physicalNetworkSnapshot{}
	}
	updated := *s
	updated.captured, updated.err = time.Now(), err
	c.snapshot.Store(&updated)
	if flightrecorder.Enabled() {
		flightrecorder.Record(flightrecorder.Event{Name: "windows_network_refresh", Code: probe.Code(err), Values: map[string]int64{"routes": int64(len(updated.routes))}})
	}
	return &updated, err
}

// Install stable process-lifetime hooks once. Reusable helper sessions refresh
// data without replacing functions that active dialers may still be calling.
func bindPhysicalRoutes() error {
	if _, err := physicalNetwork.get(true); err != nil {
		return err
	}
	physicalBindingsOnce.Do(func() {
		internet.RequiredSocketController = physicalNetwork.bind
		net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			s, err := physicalNetwork.get(false)
			if err != nil {
				return nil, err
			}
			return s.dns.Dial(ctx, network, address)
		}}
		xnet.DefaultResolver = net.DefaultResolver
		physicalNetwork.wake = make(chan struct{}, 1)
		go physicalNetwork.watchDefaults(physicalNetwork.defaults(), time.Second, internet.SocketPathChanged)
		// Notifications only invalidate; no enumeration, socket work or unregister
		// inside callbacks. Both registrations belong to this helper process.
		_, routeErr := winipcfg.RegisterRouteChangeCallback(func(winipcfg.MibNotificationType, *winipcfg.MibIPforwardRow2) { physicalNetwork.invalidate() })
		_, ifaceErr := winipcfg.RegisterInterfaceChangeCallback(func(winipcfg.MibNotificationType, *winipcfg.MibIPInterfaceRow) { physicalNetwork.invalidate() })
		physicalNetwork.dirty.Store(true)
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "windows_network_watch", Code: probe.Code(errors.Join(routeErr, ifaceErr))})
		}
	})
	return nil
}

func (c *physicalNetworkCache) invalidate() {
	c.dirty.Store(true)
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// resume reopens long-lived sockets after a sleep even when the routes look the same.
func (c *physicalNetworkCache) resume() {
	c.resumed.Store(true)
	c.invalidate()
}

// The interfaces of the IPv4 and IPv6 default routes, read now.
func (c *physicalNetworkCache) defaults() (indexes [2]uint32) {
	s, _ := c.get(true)
	for i, address := range []netip.Addr{netip.IPv4Unspecified(), netip.IPv6Unspecified()} {
		if route := selectPhysicalRoute(s.routes, address); route != nil {
			indexes[i] = route.index
		}
	}
	return indexes
}

// Sockets keep the interface they were bound to, so long-lived ones reopen or
// verify themselves through moved when a default route changes interface.
func (c *physicalNetworkCache) watchDefaults(last [2]uint32, settle time.Duration, moved func()) {
	watchSocketPath(c.wake, &c.resumed, last, settle, c.defaults, moved)
}

var queryUnbiasedInterruptTime = windows.NewLazySystemDLL("kernel32.dll").NewProc("QueryUnbiasedInterruptTime")

// windowsSuspended is the time this boot spent asleep or hibernated: the tick count
// includes it, the unbiased interrupt time does not.
func windowsSuspended() time.Duration {
	var unbiased uint64 // 100 ns units
	if ok, _, _ := queryUnbiasedInterruptTime.Call(uintptr(unsafe.Pointer(&unbiased))); ok == 0 {
		return 0
	}
	return windows.DurationSinceBoot() - time.Duration(unbiased)*100
}

func selectPhysicalRoute(routes []physicalRoute, address netip.Addr) *physicalRoute {
	zone := address.Zone()
	ip := address.Unmap().WithZone("")
	var best *physicalRoute
	for i := range routes {
		r := &routes[i]
		if zone != "" && zone != strconv.Itoa(int(r.index)) {
			continue
		}
		if r.prefix.Contains(ip) && (best == nil || r.prefix.Bits() > best.prefix.Bits() || r.prefix.Bits() == best.prefix.Bits() && r.metric < best.metric) {
			best = r
		}
	}
	return best
}

func (c *physicalNetworkCache) bind(network, address string, conn syscall.RawConn) (bindErr error) {
	var selected uint32
	var family int64
	if flightrecorder.Enabled() {
		defer func() {
			var native syscall.Errno
			errors.As(bindErr, &native)
			flightrecorder.Record(flightrecorder.Event{Name: "windows_socket_bind", Code: probe.Code(bindErr), Values: map[string]int64{"interface_index": int64(selected), "family": family, "native_error": int64(native)}})
		}()
	}
	target, err := netip.ParseAddrPort(address)
	if err != nil {
		return errors.New("route_unavailable")
	}
	ip := target.Addr().Unmap()
	family = 4
	if ip.Is6() {
		family = 6
	}
	if ip.IsLoopback() {
		return nil
	}
	for attempt := 0; attempt < 2; attempt++ {
		s, err := c.get(attempt != 0)
		if err != nil {
			return err
		}
		route := selectPhysicalRoute(s.routes, ip)
		if route == nil {
			return errors.New("route_unavailable")
		}
		selected = route.index
		// Interface indices can be reused after another VPN removes its adapter.
		// Validate the stable LUID, not just the index accepted by setsockopt.
		iface, err := route.luid.Interface()
		if err != nil || iface.InterfaceIndex != selected || iface.OperStatus != winipcfg.IfOperStatusUp {
			if attempt == 0 {
				continue
			}
			return errors.New("route_unavailable")
		}
		var socketError error
		err = conn.Control(func(fd uintptr) {
			if ip.Is6() {
				socketError = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, 31, int(selected))
			} else {
				var index [4]byte
				binary.BigEndian.PutUint32(index[:], selected)
				socketError = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31, int(binary.NativeEndian.Uint32(index[:])))
			}
		})
		if err != nil {
			return err
		}
		if attempt == 0 && (errors.Is(socketError, windows.WSAEINVAL) || errors.Is(socketError, windows.WSAEADDRNOTAVAIL)) {
			continue
		}
		return socketError
	}
	return errors.New("route_unavailable")
}

// Exclude our capture adapters on every refresh, including after TUN startup.
// Retain longest-prefix routing for LAN/overlay destinations and normal metrics.
func readPhysicalNetwork(control func(string, string, syscall.RawConn) error) (*physicalNetworkSnapshot, error) {
	rows, err := winipcfg.GetIPForwardTable2(windows.AF_UNSPEC)
	if err != nil {
		return nil, errors.New("route_unavailable")
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, errors.New("route_unavailable")
	}
	available := make(map[uint32]bool, len(interfaces))
	for _, iface := range interfaces {
		available[uint32(iface.Index)] = iface.Flags&net.FlagUp != 0 && !strings.HasPrefix(strings.ToLower(iface.Name), "elarni-")
	}
	routes := []physicalRoute{}
	metrics := map[[2]uint32]uint64{}
	for _, row := range rows {
		prefix := row.DestinationPrefix.Prefix()
		if !prefix.IsValid() || !available[row.InterfaceIndex] {
			continue
		}
		family := windows.AF_INET
		if prefix.Addr().Is6() {
			family = windows.AF_INET6
		}
		key := [2]uint32{row.InterfaceIndex, uint32(family)}
		metric, found := metrics[key]
		if !found {
			ipif, err := row.InterfaceLUID.IPInterface(winipcfg.AddressFamily(family))
			if err != nil {
				continue
			}
			metric = uint64(ipif.Metric)
			metrics[key] = metric
		}
		routes = append(routes, physicalRoute{prefix, row.InterfaceIndex, uint64(row.Metric) + metric, row.InterfaceLUID})
	}
	if len(routes) == 0 {
		return nil, errors.New("route_unavailable")
	}
	servers, err := readPhysicalDNSServers()
	if err != nil {
		return nil, err
	}
	if flightrecorder.Enabled() {
		values := map[string]int64{"routes": int64(len(routes)), "interfaces": int64(len(interfaces))}
		for _, route := range routes {
			if route.prefix.Bits() == 0 {
				if route.prefix.Addr().Is4() {
					values["ipv4_defaults"]++
				} else {
					values["ipv6_defaults"]++
				}
			}
		}
		flightrecorder.Record(flightrecorder.Event{Name: "windows_physical_routes", Values: values})
	}
	return &physicalNetworkSnapshot{routes: routes, dns: physicalResolver(servers, control)}, nil
}
