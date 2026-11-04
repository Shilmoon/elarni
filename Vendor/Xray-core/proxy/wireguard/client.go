package wireguard

import (
	"context"
	"fmt"
	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
	gonet "net"
	"net/netip"
	reflect "reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	xctx "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/dice"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/net/cnc"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal"
	"github.com/xtls/xray-core/common/task"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/proxy"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"golang.zx2c4.com/wireguard/device"
)

type Handler struct {
	conf          *DeviceConfig
	policyManager policy.Manager
	dns           dns.Client

	streamSettings  *internet.MemoryStreamConfig
	uplinkCounter   stats.Counter
	downlinkCounter stats.Counter

	tun          tun.Device
	tnet         *Net
	dev          tunnelDevice
	configured   bool // dev accepted the config; until then each dial retries IpcSet
	stopRebind   func()
	mu           sync.Mutex
	diagnosticID uint64
}

func NewClient(ctx context.Context, conf *DeviceConfig) (*Handler, error) {
	v := core.MustFromContext(ctx)
	p := v.GetFeature(policy.ManagerType()).(policy.Manager)
	d := v.GetFeature(dns.ClientType()).(dns.Client)

	streamSettings := session.StreamSettingsFromContext(ctx).(*internet.MemoryStreamConfig)
	tag := session.FullHandlerFromContext(ctx).Tag()
	var uplinkCounter stats.Counter
	var downlinkCounter stats.Counter
	if len(tag) > 0 && p.ForSystem().Stats.OutboundUplink {
		statsManager := v.GetFeature(stats.ManagerType()).(stats.Manager)
		name := "outbound>>>" + tag + ">>>traffic>>>uplink"
		c, _ := statsManager.GetOrRegisterCounter(name)
		if c != nil {
			uplinkCounter = c
		}
	}
	if len(tag) > 0 && p.ForSystem().Stats.OutboundDownlink {
		statsManager := v.GetFeature(stats.ManagerType()).(stats.Manager)
		name := "outbound>>>" + tag + ">>>traffic>>>downlink"
		c, _ := statsManager.GetOrRegisterCounter(name)
		if c != nil {
			downlinkCounter = c
		}
	}

	if len(conf.Peers) == 0 {
		return nil, errors.New("empty peers")
	}
	for _, peer := range conf.Peers {
		if peer.PublicKey == "" {
			return nil, errors.New("peer without publickey")
		}
		if peer.Endpoint == "" {
			return nil, errors.New("peer without endpoint")
		}
	}

	localAddresses := make([]netip.Addr, 0, len(conf.Endpoint))
	for _, localaddress := range conf.Endpoint {
		addr, err := netip.ParseAddr(localaddress)
		if err == nil {
			localAddresses = append(localAddresses, addr)
			continue
		}
		prefix, err := netip.ParsePrefix(localaddress)
		if err == nil {
			localAddresses = append(localAddresses, prefix.Addr())
			continue
		}
		return nil, err
	}

	kernelTunSupported, err := KernelTunSupported()
	if err != nil {
		errors.LogWarningInner(context.Background(), err, "Failed to check kernel TUN support")
	}
	var tun tun.Device
	var tnet *Net
	dnsServers := []netip.Addr{netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("1.0.0.1"), netip.MustParseAddr("2606:4700:4700::1111"), netip.MustParseAddr("2606:4700:4700::1001")}
	if len(conf.DnsServers) > 0 {
		dnsServers = nil
		for _, server := range conf.DnsServers {
			address, err := netip.ParseAddr(server)
			if err != nil {
				return nil, errors.New("invalid WireGuard DNS server")
			}
			dnsServers = append(dnsServers, address)
		}
	}
	if !conf.NoKernelTun && kernelTunSupported {
		errors.LogWarning(context.Background(), "Using kernel TUN")
		tun, tnet, err = createKernelTun(localAddresses, dnsServers, tunnelMTU(conf.Mtu, conf.Amnezia))
	} else {
		errors.LogWarning(context.Background(), "Using gVisor TUN")
		tun, tnet, _, err = CreateNetTUN(localAddresses, dnsServers, tunnelMTU(conf.Mtu, conf.Amnezia), true)
	}
	if err != nil {
		return nil, err
	}

	return &Handler{
		conf:          conf,
		policyManager: p,
		dns:           d,

		streamSettings:  streamSettings,
		uplinkCounter:   uplinkCounter,
		downlinkCounter: downlinkCounter,

		tun:          tun,
		tnet:         tnet,
		diagnosticID: flightrecorder.NextID(),
	}, nil
}

var _ proxy.LargePacketCarrier = (*Handler)(nil)

// CarriesLargePackets implements proxy.LargePacketCarrier.
func (h *Handler) CarriesLargePackets() {}

// Process implements proxy.Outbound.Process.
func (h *Handler) Process(ctx context.Context, link *transport.Link, dialer internet.Dialer) (processErr error) {
	outbounds := session.OutboundsFromContext(ctx)
	ob := outbounds[len(outbounds)-1]
	if !ob.Target.IsValid() {
		return errors.New("target not specified")
	}
	ob.Name = "wireguard"
	ob.CanSpliceCopy = 3
	diagnosticCtx := ctx
	if flightrecorder.Enabled() {
		diagnosticCtx = flightrecorder.WithConnection(ctx, flightrecorder.NextID())
		started := time.Now()
		h.diagnosticEvent(diagnosticCtx, "wg_flow_start", nil, map[string]int64{"network": int64(ob.Target.Network)})
		defer func() {
			h.diagnosticEvent(diagnosticCtx, "wg_flow_done", processErr, map[string]int64{"elapsed_ms": time.Since(started).Milliseconds()})
		}()
	}

	if err := h.init(ctx); err != nil {
		return err
	}

	var addr netip.Addr
	if ob.Target.Address.Family().IsDomain() {
		ip, err := h.resolveRemote(diagnosticCtx, ob.Target.Address.String())
		if err != nil {
			return errors.New("failed to resolve domain").Base(err)
		}
		addr, _ = netip.AddrFromSlice(ip)
	} else {
		addr, _ = netip.AddrFromSlice(ob.Target.Address.IP())
	}

	addrPort := netip.AddrPortFrom(addr, ob.Target.Port.Value())
	if !addrPort.IsValid() {
		return errors.New("invalid target ", ob.Target)
	}

	var newCtx context.Context
	var newCancel context.CancelFunc
	if session.TimeoutOnlyFromContext(ctx) {
		newCtx, newCancel = context.WithCancel(context.Background())
	}

	sessionPolicy := h.policyManager.ForLevel(0)
	ctx, cancel := context.WithCancel(ctx)
	timer := signal.CancelAfterInactivity(ctx, func() {
		cancel()
		if newCancel != nil {
			newCancel()
		}
	}, sessionPolicy.Timeouts.ConnectionIdle)

	if newCtx != nil {
		ctx = newCtx
	}

	var reader buf.Reader
	var writer buf.Writer

	switch ob.Target.Network {
	case net.Network_TCP:
		var conn net.Conn
		var err error
		var started time.Time
		if flightrecorder.Enabled() {
			started = time.Now()
			h.diagnosticEvent(diagnosticCtx, "wg_tcp_dial_start", nil, map[string]int64{"family": diagnosticFamily(addr)})
		}
		if sessionPolicy.Timeouts.Handshake != 0 {
			timeoutCtx, timeoutCancel := context.WithTimeout(ctx, sessionPolicy.Timeouts.Handshake)
			conn, err = h.tnet.DialContextTCPAddrPort(timeoutCtx, addrPort)
			timeoutCancel()
		} else {
			conn, err = h.tnet.DialContextTCPAddrPort(ctx, addrPort)
		}
		if flightrecorder.Enabled() {
			h.diagnosticEvent(diagnosticCtx, "wg_tcp_dial_done", err, map[string]int64{"family": diagnosticFamily(addr), "elapsed_ms": time.Since(started).Milliseconds()})
		}
		if err != nil {
			return errors.New("failed to create TCP connection").Base(err)
		}
		if flightrecorder.Enabled() {
			conn = flightrecorder.TrackConn(conn, flightrecorder.Connection(diagnosticCtx), uint32(xctx.IDFromContext(diagnosticCtx)), "wg_tcp")
		}
		defer conn.Close()
		reader = buf.NewReader(conn)
		writer = buf.NewWriter(conn)
	case net.Network_UDP:
		conn, err := h.tnet.DialUDPAddrPort(netip.AddrPort{}, addrPort)
		if err != nil {
			return errors.New("failed to create UDP connection").Base(err)
		}
		packetConn := conn.(*net.PacketConnWrapper).PacketConn
		if flightrecorder.Enabled() {
			packetConn = flightrecorder.TrackPacketConn(packetConn, flightrecorder.Connection(diagnosticCtx), uint32(xctx.IDFromContext(diagnosticCtx)), "wg_udp")
		}
		defer packetConn.Close()
		c := &udpConnClient{
			PacketConn:  packetConn,
			resolveFunc: func(host string) (net.IP, error) { return h.resolveRemote(diagnosticCtx, host) },
			dest:        gonet.UDPAddrFromAddrPort(addrPort),
		}
		reader = c
		writer = c
	default:
		panic(ob.Target.Network)
	}

	requestFunc := func() error {
		defer timer.SetTimeout(sessionPolicy.Timeouts.DownlinkOnly)
		return buf.Copy(link.Reader, writer, buf.UpdateActivity(timer))
	}

	responseFunc := func() error {
		defer timer.SetTimeout(sessionPolicy.Timeouts.UplinkOnly)
		return buf.Copy(reader, link.Writer, buf.UpdateActivity(timer))
	}

	responseDonePost := task.OnSuccess(responseFunc, task.Close(link.Writer))
	if err := task.Run(ctx, requestFunc, responseDonePost); err != nil {
		common.Interrupt(link.Reader)
		common.Interrupt(link.Writer)
		return errors.New("connection ends").Base(err)
	}

	return nil
}

func (h *Handler) Close() (err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stopRebind != nil {
		h.stopRebind()
		h.stopRebind = nil
	}
	if h.dev != nil {
		h.dev.Close()
		h.dev = nil
		h.tun = nil
	} else if h.tun != nil {
		h.tun.Close()
		h.tun = nil
	}
	return nil
}

// A device closes h.tun when it closes, so h keeps one device until Close and a
// failed start leaves it for the next dial to retry.
func (h *Handler) newDevice(ctx context.Context) tunnelDevice {
	resolveFunc := h.resolveLocal
	listenFunc := func() (_ net.PacketConn, listenErr error) {
		if flightrecorder.Enabled() {
			started := time.Now()
			h.diagnosticEvent(context.Background(), "wg_bind_start", nil, nil)
			defer func() {
				h.diagnosticEvent(context.Background(), "wg_bind_done", listenErr, map[string]int64{"elapsed_ms": time.Since(started).Milliseconds()})
			}()
		}
		dest, err := net.ParseDestination("udp:" + h.conf.Peers[0].Endpoint)
		if err != nil {
			return nil, err
		}
		var pktConn net.PacketConn
		if h.streamSettings.FinalMask != nil {
			conn, err := h.streamSettings.FinalMask.DialUDP(ctx, dest)
			if err != nil {
				return nil, err
			}
			pktConn = conn.(*net.PacketConnWrapper).PacketConn
		} else {
			conn, err := internet.DialSystem(ctx, dest, h.streamSettings.SocketSettings)
			if err != nil {
				return nil, err
			}
			switch c := conn.(type) {
			case *net.PacketConnWrapper:
				pktConn = c.PacketConn
			case *cnc.Connection:
				pktConn = &internet.FakePacketConn{Conn: c}
			default:
				panic(reflect.TypeOf(c))
			}
		}
		if h.uplinkCounter != nil || h.downlinkCounter != nil {
			pktConn = &PacketCounterConnection{
				PacketConn:   pktConn,
				ReadCounter:  h.downlinkCounter,
				WriteCounter: h.uplinkCounter,
			}
		}
		if flightrecorder.Enabled() {
			pktConn = flightrecorder.TrackPacketConn(pktConn, h.diagnosticID, 0, "wg_transport")
		}
		return pktConn, nil
	}
	bind := &bind{resolveFunc: resolveFunc, listenFunc: listenFunc, reserved: h.conf.Reserved, preserveHeader: h.conf.Amnezia}
	logger := &device.Logger{
		Verbosef: func(format string, args ...any) {
			log.Record(&log.GeneralMessage{
				Severity: log.Severity_Debug,
				Content:  fmt.Sprintf(format, args...),
			})
		},
		Errorf: func(format string, args ...any) {
			log.Record(&log.GeneralMessage{
				Severity: log.Severity_Error,
				Content:  fmt.Sprintf(format, args...),
			})
		},
	}
	var dev tunnelDevice
	if h.conf.Amnezia {
		dev = awg.NewDevice(adaptAmneziaTUN(h.tun), &amneziaBind{bind}, &awg.Logger{Verbosef: logger.Verbosef, Errorf: logger.Errorf})
	} else {
		dev = device.NewDevice(h.tun, bind, logger)
	}
	bind.downFunc = dev.Down
	// The socket keeps the interface it was bound to; reopen it on the new one.
	h.stopRebind = internet.OnSocketPathChange(func() {
		go func() {
			if dev.BindUpdate() != nil {
				dev.Down() // the next dial retries Up, as after a failed start
			}
		}()
	})
	return dev
}

func (h *Handler) init(ctx context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.tun == nil {
		return errors.New("closed")
	}
	if h.configured {
		return h.dev.Up()
	}
	if h.dev == nil {
		h.dev = h.newDevice(context.WithoutCancel(ctx)) // the device outlives the dial that starts it
	}
	var cfg strings.Builder
	cfg.WriteString("private_key=" + h.conf.SecretKey + "\n")
	keys := make([]string, 0, len(h.conf.AmneziaSettings))
	for key := range h.conf.AmneziaSettings {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		cfg.WriteString(key + "=" + h.conf.AmneziaSettings[key] + "\n")
	}
	for _, peer := range h.conf.Peers {
		cfg.WriteString("public_key=" + peer.PublicKey + "\n")
		if peer.PreSharedKey != "" {
			cfg.WriteString("preshared_key=" + peer.PreSharedKey + "\n")
		}
		cfg.WriteString("endpoint=" + peer.Endpoint + "\n")
		for _, ip := range peer.AllowedIps {
			cfg.WriteString("allowed_ip=" + ip + "\n")
		}
		if peer.KeepAlive != "" {
			cfg.WriteString("persistent_keepalive_interval=" + peer.KeepAlive + "\n")
		}
	}
	err := h.dev.IpcSet(cfg.String())
	if err != nil {
		return err
	}
	h.configured = true
	return h.dev.Up()
}

func (h *Handler) resolveLocal(host string) (net.IP, error) {
	return resolveDomain(host, h.conf.DomainStrategy, func(host string) ([]net.IP, error) {
		ips, _, err := h.dns.LookupIP(host, dns.IPOption{IPv4Enable: true, IPv6Enable: true})
		return ips, err
	})
}

func (h *Handler) resolveRemote(ctx context.Context, host string) (ip net.IP, resolveErr error) {
	if flightrecorder.Enabled() {
		started := time.Now()
		h.diagnosticEvent(ctx, "wg_dns_start", nil, nil)
		defer func() {
			addr, _ := netip.AddrFromSlice(ip)
			h.diagnosticEvent(ctx, "wg_dns_done", resolveErr, map[string]int64{"elapsed_ms": time.Since(started).Milliseconds(), "family": diagnosticFamily(addr)})
		}()
	}
	return resolveDomain(host, h.conf.DomainStrategy, func(host string) ([]net.IP, error) {
		addrs, err := h.tnet.LookupHost(host)
		if err != nil {
			return nil, err
		}
		ips := make([]net.IP, 0, len(addrs))
		for _, addr := range addrs {
			ips = append(ips, net.ParseIP(addr))
		}
		return ips, nil
	})
}

func resolveDomain(host string, strategy DeviceConfig_DomainStrategy, lookupIP func(host string) ([]net.IP, error)) (net.IP, error) {
	if ip := net.ParseIP(host); ip != nil {
		return ip, nil
	}
	ips, err := lookupIP(host)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, dns.ErrEmptyResponse
	}
	var got4, got6 []net.IP
	for _, ip := range ips {
		if ip.To4() != nil {
			got4 = append(got4, ip)
		} else {
			got6 = append(got6, ip)
		}
	}
	var got []net.IP
	switch strategy {
	case DeviceConfig_FORCE_IP:
		got = ips
		return ips[dice.Roll(len(ips))], nil
	case DeviceConfig_FORCE_IP4:
		got = got4
	case DeviceConfig_FORCE_IP6:
		got = got6
	case DeviceConfig_FORCE_IP46:
		got = got4
		if len(got) == 0 {
			got = got6
		}
	case DeviceConfig_FORCE_IP64:
		got = got6
		if len(got) == 0 {
			got = got4
		}
	default:
		panic(strategy)
	}
	if len(got) == 0 {
		return nil, dns.ErrEmptyResponse
	}
	return got[dice.Roll(len(got))], nil
}

type udpConnClient struct {
	net.PacketConn
	resolveFunc func(host string) (net.IP, error)
	dest        *net.UDPAddr
	scratch     []byte
}

func (c *udpConnClient) ReadMultiBuffer() (buf.MultiBuffer, error) {
	// Read the whole datagram, then size its buffer to the data, as freedom does.
	if c.scratch == nil {
		c.scratch = make([]byte, buf.UDPSize)
	}
	n, addr, err := c.PacketConn.ReadFrom(c.scratch)
	if err != nil {
		return nil, err
	}
	b := buf.NewWithSize(int32(n))
	b.Write(c.scratch[:n])

	b.UDP = &net.Destination{
		Address: net.IPAddress(addr.(*net.UDPAddr).IP),
		Port:    net.Port(addr.(*net.UDPAddr).Port),
		Network: net.Network_UDP,
	}

	return buf.MultiBuffer{b}, nil
}

func (c *udpConnClient) WriteMultiBuffer(mb buf.MultiBuffer) error {
	for i, b := range mb {
		dst := c.dest
		if b.UDP != nil {
			if b.UDP.Address.Family().IsDomain() {
				ip, err := c.resolveFunc(b.UDP.Address.String())
				if err != nil {
					errors.LogErrorInner(context.Background(), err, "drop packet to ", b.UDP, " with size ", len(b.Bytes()))
					b.Release()
					continue
				}
				dst = &net.UDPAddr{
					IP:   ip,
					Port: int(b.UDP.Port),
				}
			} else {
				dst = b.UDP.RawNetAddr().(*net.UDPAddr)
			}
		}
		_, err := c.PacketConn.WriteTo(b.Bytes(), dst)
		if err != nil {
			buf.ReleaseMulti(mb[i:])
			return err
		}
		b.Release()
	}
	return nil
}

type PacketCounterConnection struct {
	net.PacketConn
	ReadCounter  stats.Counter
	WriteCounter stats.Counter
}

func (c *PacketCounterConnection) ReadFrom(p []byte) (n int, addr net.Addr, err error) {
	n, addr, err = c.PacketConn.ReadFrom(p)
	if err == nil && c.ReadCounter != nil {
		c.ReadCounter.Add(int64(n))
	}
	return
}

func (c *PacketCounterConnection) WriteTo(p []byte, addr net.Addr) (n int, err error) {
	n, err = c.PacketConn.WriteTo(p, addr)
	if err == nil && c.WriteCounter != nil {
		c.WriteCounter.Add(int64(n))
	}
	return
}

// tunnelMTU keeps tunnel packets within the standard engine's message buffers, which the
// Elarni wireguard-go fork sizes for one packet; AmneziaWG keeps 64 KiB buffers for its padding.
func tunnelMTU(mtu int32, amnezia bool) int {
	if amnezia {
		return int(mtu)
	}
	return min(int(mtu), device.MaxContentSize)
}
