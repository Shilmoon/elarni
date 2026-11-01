//go:build windows

package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"github.com/xtls/libxray/share"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/windows"
)

// testGuardName keeps these tests off the name this host's connected VPN holds.
func testGuardName(t *testing.T) *uint16 {
	previous := guardOwnerName
	guardOwnerName = `Global\Elarni-VPN-DNS-Guard-` + t.Name()
	t.Cleanup(func() { guardOwnerName = previous })
	name, _ := windows.UTF16PtrFromString(guardOwnerName)
	return name
}

// Repair and every Windows connect after a crash run --clear-guard. A guard
// whose helper still runs, this user's or another's, must survive it.
func TestStaleGuardClearSparesALiveHelper(t *testing.T) {
	testGuardName(t)
	live, err := claimGuard()
	if errors.Is(err, windows.ERROR_INVALID_OWNER) {
		t.Skip("only an elevated helper can own the DNS guard")
	}
	if err != nil {
		t.Fatal(err)
	}
	released := 0
	release := func() error { released++; return nil }
	_, second := claimGuard()
	cleared := clearStaleGuard(release)
	found := liveGuard()
	windows.CloseHandle(live)
	if !errors.Is(second, windows.ERROR_ALREADY_EXISTS) || !found {
		t.Fatal("a live helper's DNS guard was not recognized:", second)
	}
	if released != 0 || cleared != nil {
		t.Fatal("a live helper's DNS guard was released:", cleared)
	}
	if clearStaleGuard(release) != nil || released != 1 {
		t.Fatal("a DNS guard without a live helper was kept")
	}
}

// Any unelevated program can create the guard's name; it must not block
// Connect, or make Repair keep a crashed helper's DNS block.
func TestSquattedGuardNameBlocksNothing(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	squats := map[string]func(*uint16) (windows.Handle, error){
		"open event": func(name *uint16) (windows.Handle, error) {
			return squatEvent(name, "O:"+user.User.Sid.String()+"D:(A;;GA;;;WD)")
		},
		"denying event": func(name *uint16) (windows.Handle, error) {
			return squatEvent(name, "O:"+user.User.Sid.String()+"D:")
		},
		"mutex": func(name *uint16) (windows.Handle, error) { return windows.CreateMutex(nil, false, name) },
	}
	for kind, squat := range squats {
		t.Run(kind, func(t *testing.T) {
			handle, err := squat(testGuardName(t))
			if err != nil {
				t.Fatal(err)
			}
			defer windows.CloseHandle(handle)
			if liveGuard() {
				t.Fatal("a squatted name passed for a live helper")
			}
			owner, err := claimGuard()
			if err != nil {
				t.Fatal("a squatted name blocked Connect:", err)
			}
			windows.CloseHandle(owner)
			released := 0
			if clearStaleGuard(func() error { released++; return nil }) != nil || released != 1 {
				t.Fatal("a squatted name kept a crashed helper's DNS block")
			}
		})
	}
}

func squatEvent(name *uint16, sddl string) (windows.Handle, error) {
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return 0, err
	}
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	return windows.CreateEvent(&attributes, 1, 0, name)
}

// Windows lists the fec0:0:0:ffff::1-3 placeholders on interfaces without IPv6
// DNS, the always-up loopback pseudo-interface included; nothing answers there.
func TestPhysicalDNSSkipsSiteLocalPlaceholders(t *testing.T) {
	servers, err := readPhysicalDNSServers()
	if err != nil {
		t.Fatal(err)
	}
	for _, server := range servers {
		host, _, _ := net.SplitHostPort(server)
		if address, err := netip.ParseAddr(host); err != nil || netip.MustParsePrefix("fec0::/10").Contains(address) {
			t.Fatalf("physical DNS servers %v include %s", servers, server)
		}
	}
}

func TestPhysicalDNSUsesSharedXrayResolver(t *testing.T) {
	previous, previousXray, previousControl := net.DefaultResolver, xnet.DefaultResolver, internet.RequiredSocketController
	t.Cleanup(func() {
		net.DefaultResolver, xnet.DefaultResolver = previous, previousXray
		internet.RequiredSocketController = previousControl
	})
	if err := bindPhysicalRoutes(); err != nil {
		t.Fatal(err)
	}
	if xnet.DefaultResolver != net.DefaultResolver || !net.DefaultResolver.PreferGo || net.DefaultResolver.Dial == nil {
		t.Fatal("standard and Xray DNS must share the current interface-bound resolver")
	}
}

func TestPhysicalResolverBypassesSystemDNSAndHonorsSocketBinding(t *testing.T) {
	server, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		packet := make([]byte, 4096)
		for {
			n, peer, err := server.ReadFrom(packet)
			if err != nil {
				return
			}
			var query dnsmessage.Message
			if query.Unpack(packet[:n]) != nil || len(query.Questions) != 1 {
				continue
			}
			question := query.Questions[0]
			reply := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, RecursionAvailable: true}, Questions: query.Questions}
			answer := dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: question.Type, Class: dnsmessage.ClassINET, TTL: 1}}
			switch question.Type {
			case dnsmessage.TypeA:
				answer.Body = &dnsmessage.AResource{A: [4]byte{198, 18, 0, 1}}
			case dnsmessage.TypeAAAA:
				answer.Body = &dnsmessage.AAAAResource{AAAA: [16]byte{0x20, 1, 0xd, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}}
			default:
				continue
			}
			reply.Answers = []dnsmessage.Resource{answer}
			data, err := reply.Pack()
			if err == nil {
				_, _ = server.WriteTo(data, peer)
			}
		}
	}()
	var bindings atomic.Int32
	resolver := physicalResolver([]string{server.LocalAddr().String()}, func(network, address string, _ syscall.RawConn) error {
		if address != server.LocalAddr().String() {
			return errors.New("lookup escaped captured DNS")
		}
		bindings.Add(1)
		return nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for family, expected := range map[string]string{"ip4": "198.18.0.1", "ip6": "2001:db8::1"} {
		ips, err := resolver.LookupIP(ctx, family, "physical-fixture.elarni.test.")
		if err != nil || len(ips) != 1 || ips[0].String() != expected {
			t.Fatalf("captured DNS failed: %v %v", ips, err)
		}
	}
	if bindings.Load() < 2 {
		t.Fatal("DNS skipped physical socket binding")
	}
	conn, err := resolver.Dial(ctx, "udp", net.JoinHostPort(share.TunDNS4, "53"))
	if err != nil {
		t.Fatal(err)
	}
	if conn.RemoteAddr().String() != server.LocalAddr().String() {
		t.Fatal("synthetic DNS was not replaced")
	}
	conn.Close()
	if _, err := physicalResolver(nil, nil).Dial(ctx, "udp", net.JoinHostPort(share.TunDNS4, "53")); err == nil {
		t.Fatal("missing physical DNS fell back to the TUN")
	}
	denied := physicalResolver([]string{server.LocalAddr().String()}, func(string, string, syscall.RawConn) error { return errors.New("binding denied") })
	if conn, err := denied.Dial(ctx, "udp", net.JoinHostPort(share.TunDNS4, "53")); err == nil {
		conn.Close()
		t.Fatal("binding failure was ignored")
	}
}
