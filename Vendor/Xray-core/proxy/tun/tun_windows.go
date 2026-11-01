//go:build windows

package tun

import (
	"crypto/md5"
	"encoding/binary"
	go_errors "errors"
	"math/bits"
	"net"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/probe"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

//go:linkname procyield runtime.procyield
func procyield(cycles uint32)

// WindowsTun is an object that handles tun network interface on Windows
// current version is heavily stripped to do nothing more,
// then create a network interface, to be provided as endpoint to gVisor ip stack
type WindowsTun struct {
	sync.RWMutex

	options                                              *Config
	adapter                                              *wintun.Adapter
	session                                              wintun.Session
	readWait                                             windows.Handle
	luid                                                 winipcfg.LUID
	changeCallback                                       winipcfg.ChangeCallback
	closed, started                                      atomic.Bool
	closeOnce                                            sync.Once
	diagnosticID                                         uint64
	diagnosticStop                                       chan struct{}
	packetsRead, packetsWritten, bytesRead, bytesWritten atomic.Int64
}

// WindowsTun implements Tun
var _ Tun = (*WindowsTun)(nil)

// WindowsTun implements GVisorDevice
var _ GVisorDevice = (*WindowsTun)(nil)

// NewTun creates a Wintun interface with the given name. Should a Wintun
// interface with the same name exist, it tried to be reused.
func NewTun(options *Config) (Tun, error) {
	adapter, session, err := startAdapter(options)
	// A device that was disabled when its helper exited comes back disabled under
	// the same GUID; closing the failed attempt removes it, so the next one starts clean.
	if go_errors.Is(err, windows.ERROR_DEVICE_NOT_AVAILABLE) {
		adapter, session, err = startAdapter(options)
	}
	if err != nil {
		return nil, err
	}

	tun := &WindowsTun{
		options:  options,
		adapter:  adapter,
		session:  session,
		readWait: session.ReadWaitEvent(),
		luid:     winipcfg.LUID(adapter.LUID()),
	}
	if flightrecorder.Enabled() {
		tun.diagnosticID = flightrecorder.NextID()
		tun.diagnosticStop = make(chan struct{})
		flightrecorder.Record(flightrecorder.Event{Name: "tun_open", Connection: tun.diagnosticID})
		go func() {
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ticker.C:
					tun.recordPackets()
				case <-tun.diagnosticStop:
					return
				}
			}
		}()
	}

	return tun, nil
}

func startAdapter(options *Config) (*wintun.Adapter, wintun.Session, error) {
	adapter, err := unpark(options.Name, options.Desc)
	if err != nil {
		return nil, wintun.Session{}, err
	}
	// start the interface with ring buffer capacity of 8 MiB
	session, err := adapter.StartSession(0x800000)
	if err != nil {
		_ = adapter.Close()
		return nil, wintun.Session{}, err
	}
	return adapter, session, nil
}

// AdapterGUID is the deterministic GUID requested for the named adapter. Windows
// NLA keys a network profile on it, so one name keeps one profile.
func AdapterGUID(name string) *windows.GUID {
	id := md5.Sum([]byte(name))
	return (*windows.GUID)(unsafe.Pointer(&id[0]))
}

func open(name, desc string) (*wintun.Adapter, error) {
	// try to create adapter anew
	adapter, err := wintun.CreateAdapter(name, desc, AdapterGUID(name))
	if err == nil {
		return adapter, nil
	}
	return nil, err
}

func (t *WindowsTun) Start() error {
	var has4, has6 bool
	allowedIPs := make([]netip.Prefix, 0, len(t.options.AutoSystemRoutingTable))
	for _, route := range t.options.AutoSystemRoutingTable {
		allowedIPs = append(allowedIPs, netip.MustParsePrefix(route))
	}
	routesMap := make(map[winipcfg.RouteData]struct{})
	for _, ip := range allowedIPs {
		route := winipcfg.RouteData{
			Destination: ip.Masked(),
			Metric:      0,
		}
		if ip.Addr().Is4() {
			has4 = true
			route.NextHop = netip.IPv4Unspecified()
		} else {
			has6 = true
			route.NextHop = netip.IPv6Unspecified()
		}
		routesMap[route] = struct{}{}
	}
	routesData := make([]*winipcfg.RouteData, 0, len(routesMap))
	for route := range routesMap {
		r := route
		routesData = append(routesData, &r)
	}
	err := t.flushRoutes()
	if err == nil {
		err = t.luid.AddRoutes(routesData)
	}
	if err != nil {
		return errors.New("unable to set routes").Base(err)
	}

	if len(t.options.Gateway) > 0 {
		addresses := make([]netip.Prefix, 0, len(t.options.Gateway))
		for _, address := range t.options.Gateway {
			addresses = append(addresses, netip.MustParsePrefix(address))
		}
		err := t.luid.SetIPAddresses(addresses)
		if err != nil {
			return errors.New("unable to set ips").Base(err)
		}
	}

	if has4 {
		ipif, err := t.luid.IPInterface(windows.AF_INET)
		if err != nil {
			return err
		}
		ipif.RouterDiscoveryBehavior = winipcfg.RouterDiscoveryDisabled
		ipif.DadTransmits = 0
		ipif.ManagedAddressConfigurationSupported = false
		ipif.OtherStatefulConfigurationSupported = false
		ipif.NLMTU = t.options.MTU
		ipif.UseAutomaticMetric = false
		ipif.Metric = 0
		err = ipif.Set()
		if err != nil {
			return err
		}
	}
	if has6 {
		ipif, err := t.luid.IPInterface(windows.AF_INET6)
		if err != nil {
			return err
		}
		ipif.RouterDiscoveryBehavior = winipcfg.RouterDiscoveryDisabled
		ipif.DadTransmits = 0
		ipif.ManagedAddressConfigurationSupported = false
		ipif.OtherStatefulConfigurationSupported = false
		ipif.NLMTU = t.options.MTU
		ipif.UseAutomaticMetric = false
		ipif.Metric = 0
		err = ipif.Set()
		if err != nil {
			return err
		}
	}

	if len(t.options.DNS) > 0 {
		dns := make([]netip.Addr, 0, len(t.options.DNS))
		for _, ip := range t.options.DNS {
			dns = append(dns, netip.MustParseAddr(ip))
		}
		err := t.luid.SetDNS(windows.AF_INET, dns, nil)
		if err != nil {
			return err
		}
		err = t.luid.SetDNS(windows.AF_INET6, dns, nil)
		if err != nil {
			return err
		}
	}

	if updater != nil {
		t.changeCallback, err = winipcfg.RegisterInterfaceChangeCallback(func(notificationType winipcfg.MibNotificationType, iface *winipcfg.MibIPInterfaceRow) {
			updater.Update()
		})
		if err != nil {
			return err
		}
	}

	t.started.Store(true)
	return nil
}

func (t *WindowsTun) Close() error {
	t.closeOnce.Do(func() {
		t.closed.Store(true)
		if flightrecorder.Enabled() {
			close(t.diagnosticStop)
		}
		// Wake Wait before joining readers and destroying their session/event.
		windows.SetEvent(t.readWait)
		t.Lock()
		defer t.Unlock()
		if t.changeCallback != nil {
			t.changeCallback.Unregister()
		}
		// Ending the session first takes the adapter media-down, so Windows stops
		// routing into it before its routes, addresses and DNS are removed.
		t.session.End()
		// A failed start gets a fresh adapter next time.
		if !t.started.Load() || t.park() != nil {
			_ = t.adapter.Close()
		}
		if flightrecorder.Enabled() {
			t.recordPackets()
			flightrecorder.Record(flightrecorder.Event{Name: "tun_closed", Connection: t.diagnosticID})
		}
	})

	return nil
}

// parked keeps one closed runtime's adapter for the next runtime in this
// process, saving Wintun's ~1 s create and ~1 s remove per reconnect. Wintun
// removes it when the process exits, crash included.
var parked struct {
	sync.Mutex
	name    string
	adapter *wintun.Adapter
}

// unpark takes the adapter parked under name, or opens a new one.
func unpark(name, desc string) (*wintun.Adapter, error) {
	parked.Lock()
	adapter, same := parked.adapter, parked.name == name
	parked.adapter = nil
	parked.Unlock()
	if adapter != nil {
		if same {
			return adapter, nil
		}
		_ = adapter.Close()
	}
	return open(name, desc)
}

// park keeps the adapter only once it captures nothing: no session, routes,
// addresses or DNS servers.
func (t *WindowsTun) park() error {
	err := errors.Combine(t.flushRoutes(), t.luid.FlushIPAddresses(windows.AF_UNSPEC),
		t.luid.FlushDNS(windows.AF_INET), t.luid.FlushDNS(windows.AF_INET6))
	if err != nil {
		return err
	}
	parked.Lock()
	defer parked.Unlock()
	if parked.adapter != nil {
		return errors.New("an adapter is already parked")
	}
	parked.name, parked.adapter = t.options.Name, t.adapter
	return nil
}

// flushRoutes removes the adapter's routes. Deleting a prefix route also removes the
// broadcast route Windows derived from it, so that row of the same table read is
// already gone; winipcfg's FlushRoutes fails a parked adapter's reconnect on it.
func (t *WindowsTun) flushRoutes() error {
	rows, err := winipcfg.GetIPForwardTable2(windows.AF_UNSPEC)
	if err != nil {
		return err
	}
	for i := range rows {
		if rows[i].InterfaceLUID == t.luid {
			if err := rows[i].Delete(); err != nil && !go_errors.Is(err, windows.ERROR_NOT_FOUND) {
				return err
			}
		}
	}
	return nil
}

func (t *WindowsTun) Name() (string, error) {
	row, err := t.luid.Interface()
	if err != nil {
		return "", err
	}
	return row.Alias(), nil
}

func (t *WindowsTun) Index() (int, error) {
	row, err := t.luid.Interface()
	if err != nil {
		return 0, err
	}
	return int(row.InterfaceIndex), nil
}

// WritePacket implements GVisorDevice method to write one packet to the tun device
func (t *WindowsTun) WritePacket(packetBuffer *stack.PacketBuffer) tcpip.Error {
	t.RLock()
	defer t.RUnlock()
	if t.closed.Load() {
		return &tcpip.ErrClosedForSend{}
	}

	// request buffer from Wintun
	packet, err := t.session.AllocateSendPacket(packetBuffer.Size())
	if err != nil {
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "tun_write_error", Code: probe.Code(err), Connection: t.diagnosticID})
		}
		return &tcpip.ErrAborted{}
	}

	// copy the bytes of slices that compose the packet into the allocated buffer
	var index int
	for _, packetElement := range packetBuffer.AsSlices() {
		index += copy(packet[index:], packetElement)
	}

	// signal Wintun to send that buffer as the packet
	t.session.SendPacket(packet)
	if flightrecorder.Enabled() {
		t.packetsWritten.Add(1)
		t.bytesWritten.Add(int64(len(packet)))
	}

	return nil
}

// ReadPacket implements GVisorDevice method to read one packet from the tun device
// It is expected that the method will not block, rather return ErrQueueEmpty when there is nothing on the line,
// which will make the stack call Wait which should implement desired push-back
func (t *WindowsTun) ReadPacket() (byte, *stack.PacketBuffer, error) {
	t.RLock()
	defer t.RUnlock()
	if t.closed.Load() {
		return 0, nil, os.ErrClosed
	}
	packet, err := t.session.ReceivePacket()
	if go_errors.Is(err, windows.ERROR_NO_MORE_ITEMS) {
		return 0, nil, ErrQueueEmpty
	}
	if err != nil {
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "tun_read_error", Code: probe.Code(err), Connection: t.diagnosticID})
		}
		return 0, nil, err
	}

	defer t.session.ReleaseReceivePacket(packet)
	if len(packet) == 0 {
		return 0, nil, windows.ERROR_INVALID_DATA
	}
	version := packet[0] >> 4
	if flightrecorder.Enabled() {
		t.packetsRead.Add(1)
		t.bytesRead.Add(int64(len(packet)))
	}
	view := buffer.NewViewWithData(packet)
	clampGuestMSS(view.AsSlice())
	packetBuffer := buffer.MakeWithView(view)
	return version, stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload:           packetBuffer,
		IsForwardedPacket: true,
	}), nil
}

// clampGuestMSS caps the MSS of a TCP SYN that the Windows stack did not send at what
// a 1500-byte frame carries. WSL's mirrored networking gives its guest this adapter's
// MTU, but drops larger replies to it without ICMP (microsoft/WSL#41419). Windows sends
// with TTL 128 and keeps jumbo segments; other senders sit behind a 1500-byte link.
// The guest's own jumbo frames do reach the TUN, so gVisor's SYN-ACK keeps its MSS.
func clampGuestMSS(packet []byte) {
	var segment []byte
	limit := uint16(1500 - header.IPv4MinimumSize - header.TCPMinimumSize)
	switch {
	case len(packet) >= header.IPv4MinimumSize && packet[0]>>4 == 4:
		ip := header.IPv4(packet)
		length, total := int(ip.HeaderLength()), int(ip.TotalLength())
		if ip.TTL() >= 128 || ip.Protocol() != uint8(header.TCPProtocolNumber) || ip.FragmentOffset() != 0 ||
			length < header.IPv4MinimumSize || total < length || total > len(packet) {
			return
		}
		segment = packet[length:total]
	case len(packet) >= header.IPv6MinimumSize && packet[0]>>4 == 6:
		ip := header.IPv6(packet)
		total := header.IPv6MinimumSize + int(ip.PayloadLength())
		if ip.HopLimit() >= 128 || ip.NextHeader() != uint8(header.TCPProtocolNumber) || total > len(packet) {
			return
		}
		segment = packet[header.IPv6MinimumSize:total]
		limit = 1500 - header.IPv6MinimumSize - header.TCPMinimumSize
	default:
		return
	}
	if len(segment) < header.TCPMinimumSize {
		return
	}
	tcp := header.TCP(segment)
	offset := int(tcp.DataOffset())
	if tcp.Flags()&(header.TCPFlagSyn|header.TCPFlagAck) != header.TCPFlagSyn ||
		offset < header.TCPMinimumSize || offset > len(segment) {
		return
	}
	for at := header.TCPMinimumSize; at < offset; {
		switch segment[at] {
		case header.TCPOptionEOL:
			return
		case header.TCPOptionNOP:
			at++
			continue
		}
		if at+1 >= offset || segment[at+1] < 2 || at+int(segment[at+1]) > offset {
			return
		}
		if segment[at] == header.TCPOptionMSS && segment[at+1] == header.TCPOptionMSSLength {
			old := binary.BigEndian.Uint16(segment[at+2:])
			if old <= limit {
				return
			}
			binary.BigEndian.PutUint16(segment[at+2:], limit)
			// Incremental update (RFC 1624); a field at an odd offset sums byte-swapped.
			before, after := old, limit
			if at%2 == 1 {
				before, after = bits.ReverseBytes16(before), bits.ReverseBytes16(after)
			}
			tcp.SetChecksum(^checksum.Combine(checksum.Combine(^tcp.Checksum(), ^before), after))
			return
		}
		at += int(segment[at+1])
	}
}

func (t *WindowsTun) recordPackets() {
	flightrecorder.Record(flightrecorder.Event{Name: "tun_packets", Connection: t.diagnosticID, Values: map[string]int64{"packets_in": t.packetsRead.Load(), "packets_out": t.packetsWritten.Load(), "bytes_in": t.bytesRead.Load(), "bytes_out": t.bytesWritten.Load()}})
}

func (t *WindowsTun) Wait() {
	t.RLock()
	defer t.RUnlock()
	if t.closed.Load() {
		return
	}
	procyield(1)
	_, _ = windows.WaitForSingleObject(t.readWait, windows.INFINITE)
}

func (t *WindowsTun) newEndpoint() (stack.LinkEndpoint, error) {
	return &LinkEndpoint{deviceMTU: t.options.MTU, device: t}, nil
}

const (
	IP_UNICAST_IF   = 31
	IPV6_UNICAST_IF = 31
)

func setinterface(network, address string, fd uintptr, iface *net.Interface) error {
	var index [4]byte
	binary.BigEndian.PutUint32(index[:], uint32(iface.Index))

	var err1, err2, err3, err4 error

	switch network {
	case "tcp6", "udp6", "ip6":
		err1 = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, IPV6_UNICAST_IF, iface.Index)
		if network == "udp6" {
			err2 = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, windows.IPV6_MULTICAST_IF, iface.Index)
		}
		fallthrough
	case "tcp4", "udp4", "ip4":
		err3 = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, IP_UNICAST_IF, *(*int)(unsafe.Pointer(&index[0])))
		if network == "udp4" || network == "udp6" {
			err4 = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, windows.IP_MULTICAST_IF, *(*int)(unsafe.Pointer(&index[0])))
		}
	default:
		panic(network + " " + address)
	}

	return errors.Combine(err1, err2, err3, err4)
}

func findOutboundInterface(tunIndex int, fixedName string) (*net.Interface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	if fixedName != "" {
		for _, iface := range interfaces {
			if iface.Index != tunIndex && iface.Name == fixedName {
				return &iface, nil
			}
		}
		return nil, nil
	}

	var candidates []struct {
		index int
		score int
	}
	for i, iface := range interfaces {
		if iface.Index == tunIndex {
			continue
		}
		if strings.Contains(iface.Name, "vEthernet") {
			continue
		}
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		candidates = append(candidates, struct {
			index int
			score int
		}{i, scoreWindowsInterface(&iface, addrs)})
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].score != candidates[j].score {
			return candidates[i].score > candidates[j].score
		}
		return interfaces[candidates[i].index].Name < interfaces[candidates[j].index].Name
	})
	if len(candidates) == 0 {
		return nil, nil
	}

	iface := interfaces[candidates[0].index]
	return &iface, nil
}

func scoreWindowsInterface(iface *net.Interface, addrs []net.Addr) int {
	score := 0

	name := strings.ToLower(iface.Name)
	if strings.Contains(name, "wlan") || strings.Contains(name, "wi-fi") {
		score += 2
	}

	for _, addr := range addrs {
		if strings.HasPrefix(addr.String(), "192.168.") {
			score++
			break
		}
	}

	return score
}
