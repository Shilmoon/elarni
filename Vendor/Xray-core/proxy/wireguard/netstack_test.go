package wireguard

import (
	"context"
	"net"
	"net/netip"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

// pipeTUN copies packets from one gVisor stack to another until from closes.
func pipeTUN(from, to tun.Device) {
	bufs, sizes := [][]byte{make([]byte, 2048)}, []int{0}
	for {
		n, err := from.Read(bufs, sizes, 0)
		if err != nil {
			return
		}
		for i := 0; i < n; i++ {
			to.Write([][]byte{bufs[i][:sizes[i]]}, 0)
		}
	}
}

// Each WireGuard flow to a domain, and each UDP packet to one, resolved through
// the tunnel again; upstream keeps answers for their TTL.
func TestTunnelLookupsReuseAnswersWithinTheirTTL(t *testing.T) {
	clientTun, clientNet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, []netip.Addr{netip.MustParseAddr("10.29.0.1")}, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	defer clientTun.Close()
	serverTun, _, serverStack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.1")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	defer serverTun.Close()
	go pipeTUN(clientTun, serverTun)
	go pipeTUN(serverTun, clientTun)

	dnsAddress, dnsFamily := convertToFullAddr(netip.MustParseAddrPort("10.29.0.1:53"))
	dnsSocket, err := gonet.DialUDP(serverStack, &dnsAddress, nil, dnsFamily)
	if err != nil {
		t.Fatal(err)
	}
	defer dnsSocket.Close()
	var queries atomic.Int32
	go func() {
		buffer := make([]byte, 2048)
		for {
			n, from, err := dnsSocket.ReadFrom(buffer)
			if err != nil {
				return
			}
			var request dns.Msg
			if request.Unpack(buffer[:n]) != nil {
				continue
			}
			queries.Add(1)
			response := new(dns.Msg)
			response.SetReply(&request)
			for _, q := range request.Question {
				ttl := uint32(60)
				if q.Name == "short.test." {
					ttl = 0
				}
				response.Answer = append(response.Answer, &dns.A{Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: ttl}, A: net.ParseIP("192.0.2.29")})
			}
			if packet, err := response.Pack(); err == nil {
				dnsSocket.WriteTo(packet, from)
			}
		}
	}()

	lookup := func(host string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		addresses, err := clientNet.LookupContextHost(ctx, host)
		if err != nil || !slices.Contains(addresses, "192.0.2.29") {
			t.Fatalf("lookup %s: %v %v", host, addresses, err)
		}
	}
	for range 3 {
		lookup("cached.test")
	}
	if got := queries.Load(); got != 1 {
		t.Fatalf("%d queries for three lookups within the TTL, want 1", got)
	}
	for range 2 {
		lookup("short.test")
	}
	if got := queries.Load(); got != 3 {
		t.Fatalf("%d queries after two lookups of a TTL 0 answer, want 3", got)
	}
}

// Every packet WireGuard decrypts passes through netTun.Write; a buffer that
// never goes back to gVisor's pools leaves each one to the GC instead.
func TestInjectedPacketsReturnTheirBuffersToThePools(t *testing.T) {
	device, _, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	defer device.Close()
	packet := make([]byte, header.IPv4MinimumSize+header.UDPMinimumSize+1200)
	ip := header.IPv4(packet)
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(len(packet)),
		TTL:         64,
		Protocol:    uint8(header.UDPProtocolNumber),
		SrcAddr:     tcpip.AddrFrom4([4]byte{10, 29, 0, 1}),
		DstAddr:     tcpip.AddrFrom4([4]byte{10, 29, 0, 99}),
	})
	ip.SetChecksum(^ip.CalculateChecksum())
	header.UDP(packet[header.IPv4MinimumSize:]).Encode(&header.UDPFields{SrcPort: 1, DstPort: 9, Length: uint16(len(packet) - header.IPv4MinimumSize)})
	allocs := testing.AllocsPerRun(1000, func() {
		device.Write([][]byte{packet}, 0)
	})
	t.Logf("%.2f allocations per packet", allocs)
	if allocs >= 3 { // unreleased buffers cost 5; -race drops a quarter of pool puts
		t.Fatalf("each packet allocated %.2f times", allocs)
	}
}

// gVisor grows a receive buffer to 4 MiB for a fast reader and keeps it full once the
// reader stalls, so every stalled connection through the tunnel held about 4 MB.
func TestTunnelTCPReceiveBuffersStopAtTwoMiB(t *testing.T) {
	_, _, gstack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	defer gstack.Close()
	var sizes tcpip.TCPReceiveBufferSizeRangeOption
	if err := gstack.TransportProtocolOption(tcp.ProtocolNumber, &sizes); err != nil {
		t.Fatal(err)
	}
	if sizes.Max != 2<<20 || sizes.Default > sizes.Max {
		t.Fatalf("receive buffer range %+v, want at most 2 MiB", sizes)
	}
}

// Each queued packet held a 64 KiB buffer on desktop and Android although packets never
// exceed the MTU here; the tunnel MTU must then fit the smaller buffers.
func TestStandardEngineBuffersFitTheTunnelMTU(t *testing.T) {
	if device.MaxSegmentSize > 2048 {
		t.Fatalf("message buffers of %d bytes per packet", device.MaxSegmentSize)
	}
	if got := tunnelMTU(9000, false); got != device.MaxContentSize {
		t.Fatalf("MTU 9000 kept as %d, want it lowered to %d", got, device.MaxContentSize)
	}
	if got := tunnelMTU(1420, false); got != 1420 {
		t.Fatalf("MTU 1420 changed to %d", got)
	}
	if got := tunnelMTU(9000, true); got != 9000 {
		t.Fatalf("AmneziaWG MTU 9000 changed to %d; its engine keeps 64 KiB buffers", got)
	}
}

// wireguard-go took one packet per read from gVisor, with a goroutine handoff each;
// packets already queued are now encrypted and sent as one batch.
func TestTunnelReadsQueuedPacketsInOneBatch(t *testing.T) {
	device, tnet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	defer device.Close()
	if device.BatchSize() < 8 {
		t.Fatalf("batch size %d", device.BatchSize())
	}
	udp, err := tnet.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort("10.29.0.1:9"))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	written := make(chan struct{})
	go func() {
		defer close(written)
		for range 5 {
			udp.Write([]byte("datagram"))
		}
	}()
	select {
	case <-written:
	case <-time.After(2 * time.Second):
		t.Fatal("writes waited for reads one packet at a time")
	}
	bufs, sizes := make([][]byte, 8), make([]int, 8)
	for i := range bufs {
		bufs[i] = make([]byte, 2048)
	}
	n, err := device.Read(bufs, sizes, 0)
	if err != nil || n != 5 {
		t.Fatalf("read %d packets (%v), want the 5 queued ones", n, err)
	}
	for i := range n {
		if packet := header.IPv4(bufs[i][:sizes[i]]); !packet.IsValid(sizes[i]) || packet.TotalLength() != uint16(sizes[i]) {
			t.Fatalf("packet %d malformed: %x", i, bufs[i][:sizes[i]])
		}
	}
}
