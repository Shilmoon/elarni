//go:build linux

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"reflect"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/xtls/libxray/share"
	"golang.org/x/sys/unix"
)

const linuxConfigFixture = `{"inbounds":[{"tag":"elarni-tun","protocol":"tun","settings":{"name":"foreign","autoSystemRoutingTable":["0.0.0.0/0"]}},{"tag":"elarni-socks","protocol":"socks","listen":"127.0.0.1","port":10890}],"outbounds":[{"tag":"direct","protocol":"freedom"}],"dns":{"servers":["localhost"]}}`

func TestLinuxTunnelOwnsCaptureAndKeepsProfileDNS(t *testing.T) {
	network := linuxNetwork{Name: "rv0123456789ab", DNSPort: 35123}
	encoded, err := linuxTunnelConfig([]byte(linuxConfigFixture), network, nil)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Inbounds []struct {
			Protocol, Tag, Listen string
			Port                  int
			Settings              struct {
				Name                   string
				AutoSystemRoutingTable []string
				Port                   int
			}
		}
		Outbounds []struct{ Tag, Protocol string }
		DNS       struct{ Servers []string }
	}
	if json.Unmarshal(encoded, &config) != nil {
		t.Fatal("invalid compiled graph")
	}
	if len(config.Inbounds) != 4 || config.Inbounds[0].Settings.Name != network.Name || len(config.Inbounds[0].Settings.AutoSystemRoutingTable) != 0 {
		t.Fatal("foreign/main-table capture survived validation")
	}
	if config.Inbounds[1].Protocol != "socks" || config.Inbounds[1].Port != 10890 {
		t.Fatal("local proxy contract changed")
	}
	for i, address := range []string{"127.0.0.1", "::1"} {
		inbound := config.Inbounds[i+2]
		if inbound.Listen != address || inbound.Port != 35123 || inbound.Settings.Port != 53 || inbound.Protocol != "dokodemo-door" {
			t.Fatal("DNS family/port not captured")
		}
	}
	if !reflect.DeepEqual(config.DNS.Servers, []string{"localhost"}) {
		t.Fatal("profile DNS was replaced")
	}
	if last := config.Outbounds[len(config.Outbounds)-1]; last.Tag != "elarni-linux-dns" || last.Protocol != "dns" {
		t.Fatal("system DNS bypasses profile policy")
	}
}

func TestLinuxWithoutIPv6RejectsTunnelledIPv6InsteadOfLeaking(t *testing.T) {
	guarded := func(noIPv6 bool, policy *share.WindowsRoutePolicy) []netip.Prefix {
		prefixes, err := linuxGuardedRoutes(linuxNetwork{NoIPv6: noIPv6}, policy)
		if err != nil {
			t.Fatal(err)
		}
		return prefixes
	}
	covers := func(prefixes []netip.Prefix, address string) bool {
		for _, prefix := range prefixes {
			if prefix.Contains(netip.MustParseAddr(address)) {
				return true
			}
		}
		return false
	}
	if got := guarded(false, nil); len(got) != 0 {
		t.Fatalf("an IPv6-capable tunnel guarded %v", got)
	}
	got := guarded(true, nil)
	if !covers(got, "2001:db8::1") || covers(got, "fe80::1") || covers(got, "ff02::1") || covers(got, "::1") || covers(got, "1.1.1.1") {
		t.Fatalf("guard without IPv6 = %v", got)
	}
	got = guarded(true, &share.WindowsRoutePolicy{IncludedRoutes: []string{"10.0.0.0/8", "2001:db8::/32"}, EnforceRoutes: true})
	if fmt.Sprint(got) != "[10.0.0.0/8 2001:db8::/32]" {
		t.Fatalf("enforced guard without IPv6 = %v", got)
	}
}

// Containers and VMs forward through the host; an output-only guard lets
// their traffic leave on the physical link when the tunnel route is missing.
func TestLinuxGuardCoversForwardedTraffic(t *testing.T) {
	network := linuxNetwork{Name: "rv0123456789ab", Mark: 0x52562ee1, DNSPort: 35123}
	script := network.firewall([]netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("2001:db8::/32")})
	for _, want := range []string{
		"add chain inet rv0123456789ab forward_guard { type filter hook forward priority 0; policy accept; }",
		`add rule inet rv0123456789ab forward_guard oifname "rv0123456789ab" return`,
		"add rule inet rv0123456789ab forward_guard ip daddr @protected4 reject",
		"add rule inet rv0123456789ab forward_guard ip6 daddr @protected6 reject",
	} {
		if !bytes.Contains([]byte(script), []byte(want+"\n")) {
			t.Fatalf("missing %q in:\n%s", want, script)
		}
	}
	if unguarded := network.firewall(nil); bytes.Contains([]byte(unguarded), []byte("forward_guard")) {
		t.Fatal("forward guard installed without enforced routes")
	}
}

func TestLinuxProbeDoesNotAllocateUnsentAssets(t *testing.T) {
	var frame bytes.Buffer
	if err := linuxWriteFrame(&frame, linuxProbeRequest{Method: "ping", Sizes: map[string]int{"geoip.dat": 64 << 20}}); err != nil {
		t.Fatal(err)
	}
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	if _, err := readLinuxProbe(&frame); err == nil {
		t.Fatal("truncated assets accepted")
	}
	runtime.ReadMemStats(&after)
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 1<<20 {
		t.Fatalf("declared but unsent assets allocated %d bytes", allocated)
	}
}

// The root probe server reserves declared asset bytes before reading any, so
// concurrent same-user requests cannot pin unbounded root memory.
func TestLinuxProbeAdmitsDeclaredAssetsBeforeReadingThem(t *testing.T) {
	var frame bytes.Buffer
	if err := linuxWriteFrame(&frame, linuxProbeRequest{Method: "ping", Sizes: map[string]int{"geoip.dat": 3, "geosite.dat": 2}}); err != nil {
		t.Fatal(err)
	}
	frame.Write([]byte{1, 2, 3, 4, 5})
	var admitted int64
	if _, err := readLinuxProbeAdmitted(bytes.NewReader(frame.Bytes()), func(size int64) error { admitted = size; return io.ErrShortBuffer }); err != io.ErrShortBuffer || admitted != 5 {
		t.Fatalf("admission = %d, %v", admitted, err)
	}
	request, err := readLinuxProbeAdmitted(bytes.NewReader(frame.Bytes()), func(int64) error { return nil })
	if err != nil || !reflect.DeepEqual(request.assets, map[string][]byte{"geoip.dat": {1, 2, 3}, "geosite.dat": {4, 5}}) {
		t.Fatal("admitted assets were not read", request.assets, err)
	}
}

func TestLinuxTunnelWithoutIPv6UsesOnlyIPv4Resources(t *testing.T) {
	network := linuxNetwork{Name: "rv0123456789ab", DNSPort: 35123, NoIPv6: true}
	encoded, err := linuxTunnelConfig([]byte(linuxConfigFixture), network, nil)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Inbounds []struct {
			Listen   string
			Settings struct{ Gateway, DNS []string }
		}
		Routing struct {
			Rules []struct{ InboundTag []string }
		}
	}
	if json.Unmarshal(encoded, &config) != nil {
		t.Fatal("invalid compiled graph")
	}
	tunnel := config.Inbounds[0].Settings
	if !reflect.DeepEqual(tunnel.Gateway, []string{share.TunGateway4}) || !reflect.DeepEqual(tunnel.DNS, []string{share.TunDNS4}) {
		t.Fatalf("IPv6 tunnel addresses remain: %+v", tunnel)
	}
	if len(config.Inbounds) != 3 || config.Inbounds[2].Listen != "127.0.0.1" {
		t.Fatal("an IPv6 DNS listener remains")
	}
	if !reflect.DeepEqual(config.Routing.Rules[0].InboundTag, []string{"elarni-tun", "elarni-linux-dns0"}) {
		t.Fatalf("DNS rule names a missing listener: %v", config.Routing.Rules[0].InboundTag)
	}
	if !reflect.DeepEqual(network.families(), []int{netlink.FAMILY_V4}) {
		t.Fatal("IPv6 policy rules would still be installed")
	}
}

// The routes live in a private network namespace, which needs root; the host's
// routes are never touched, and without root the test skips.
func TestLinuxLongerPhysicalRoutesOutrankTheTunnel(t *testing.T) {
	// The namespaced thread is never unlocked, so Go discards it with the test.
	runtime.LockOSThread()
	if err := unix.Unshare(unix.CLONE_NEWNET); err != nil {
		t.Skip("a private network namespace needs root:", err)
	}
	link := func(name string, addresses ...string) int {
		if name != "lo" {
			attrs := netlink.NewLinkAttrs()
			attrs.Name = name
			if err := netlink.LinkAdd(&netlink.Dummy{LinkAttrs: attrs}); err != nil {
				t.Fatal(err)
			}
		}
		created, err := netlink.LinkByName(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, address := range addresses {
			parsed, err := netlink.ParseAddr(address)
			if err != nil {
				t.Fatal(err)
			}
			parsed.Flags = unix.IFA_F_NODAD
			if err := netlink.AddrAdd(created, parsed); err != nil {
				t.Fatal(address, err)
			}
		}
		if err := netlink.LinkSetUp(created); err != nil {
			t.Fatal(err)
		}
		return created.Attrs().Index
	}
	link("lo")
	lan := link("lan0", "192.168.1.2/24", "10.1.0.2/24", "fd00:1::2/64")
	wan := link("wan0", "203.0.113.2/24", "2001:db8::2/64")
	for _, prefix := range []string{"0.0.0.0/0", "::/0"} {
		_, destination, _ := net.ParseCIDR(prefix)
		if err := netlink.RouteAdd(&netlink.Route{LinkIndex: wan, Dst: destination}); err != nil {
			t.Fatal(prefix, err)
		}
	}
	const tunnel = -1
	for _, test := range []struct {
		name   string
		policy *share.WindowsRoutePolicy
		via    map[string]int
	}{
		{"default", nil, map[string]int{"192.168.1.10": lan, "8.8.8.8": tunnel, "fd00:1::10": lan, "2001:4860::8888": tunnel}},
		{"host beside a default", &share.WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0", "192.168.1.50/32"}}, map[string]int{"192.168.1.50": tunnel, "192.168.1.10": lan, "8.8.8.8": tunnel}},
		{"exclusion", &share.WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0"}, ExcludedRoutes: []string{"1.1.1.1/32"}}, map[string]int{"10.1.0.10": lan, "1.1.1.1": wan, "8.8.8.8": tunnel}},
		// As on macOS, all networks include the LAN, and enforced routes outrank it.
		{"all networks", &share.WindowsRoutePolicy{IncludedRoutes: []string{"8.8.8.0/24"}, IncludeAllNetworks: true}, map[string]int{"192.168.1.10": tunnel, "8.8.8.8": tunnel}},
		{"enforced", &share.WindowsRoutePolicy{IncludedRoutes: []string{"192.168.0.0/16"}, EnforceRoutes: true}, map[string]int{"192.168.1.10": tunnel, "8.8.8.8": wan}},
	} {
		network, err := reserveLinuxNetwork()
		if errors.Is(err, errLinuxFirewallUnavailable) {
			t.Skip("nftables is not installed")
		} else if err != nil {
			t.Fatal(err)
		}
		index := link(network.Name, share.TunGateway4)
		if err := network.install(test.policy); err != nil {
			t.Fatal(test.name, err)
		}
		for destination, want := range test.via {
			if want == tunnel {
				want = index
			}
			routes, err := netlink.RouteGet(net.ParseIP(destination))
			if err != nil || len(routes) == 0 || routes[0].LinkIndex != want {
				t.Errorf("%s: %s left through %v, want link %d (%v)", test.name, destination, routes, want, err)
			}
		}
		// The core's own marked traffic always leaves physically.
		if routes, err := netlink.RouteGetWithOptions(net.ParseIP("8.8.8.8"), &netlink.RouteGetOptions{Mark: network.Mark}); err != nil || routes[0].LinkIndex != wan {
			t.Errorf("%s: marked traffic left through %v (%v)", test.name, routes, err)
		}
		if err := network.cleanup(); err != nil {
			t.Fatal(test.name, err)
		}
		rules, err := netlink.RuleList(netlink.FAMILY_ALL)
		if err != nil {
			t.Fatal(err)
		}
		for _, rule := range rules {
			if rule.Mark == network.Mark {
				t.Errorf("%s: cleanup left %v", test.name, rule)
			}
		}
		if err := netlink.LinkDel(&netlink.Dummy{LinkAttrs: netlink.LinkAttrs{Index: index}}); err != nil {
			t.Fatal(err)
		}
	}
}

// A helper killed with its supervisor leaves the policy rule and the DNS redirect.
// The unelevated check reports it, unless a supervisor still runs, and the clear
// releases it. Root and a private network namespace are needed, as above.
// Every rule policyRules may install stays inside the band reserveLinuxNetwork checks.
func TestLinuxPolicyRulesStayInTheReservedPriorities(t *testing.T) {
	network := linuxNetwork{Table: 20000, Priority: 20000, Mark: 0x52564e20}
	var routes []netip.Prefix
	for bits := 0; bits <= 128; bits++ {
		routes = append(routes, netip.PrefixFrom(netip.IPv6Unspecified(), bits))
	}
	for _, rule := range network.policyRules(netlink.FAMILY_V6, routes, nil) {
		if rule.Priority <= network.Priority-linuxRulePriorities || rule.Priority > network.Priority {
			t.Fatalf("rule priority %d is outside the reserved (%d, %d]", rule.Priority, network.Priority-linuxRulePriorities, network.Priority)
		}
	}
}

func TestLinuxGuardOfAKilledTunnelIsReportedAndCleared(t *testing.T) {
	runtime.LockOSThread()
	if err := unix.Unshare(unix.CLONE_NEWNET); err != nil {
		t.Skip("a private network namespace needs root:", err)
	}
	if linuxGuardLeft() {
		t.Fatal("an empty namespace reported a guard")
	}
	network, err := reserveLinuxNetwork()
	if errors.Is(err, errLinuxFirewallUnavailable) {
		t.Skip("nftables is not installed")
	} else if err != nil {
		t.Fatal(err)
	}
	attrs := netlink.NewLinkAttrs()
	attrs.Name = network.Name
	if err := netlink.LinkAdd(&netlink.Dummy{LinkAttrs: attrs}); err != nil {
		t.Fatal(err)
	}
	tunnel, err := netlink.LinkByName(network.Name)
	if err != nil {
		t.Fatal(err)
	}
	address, _ := netlink.ParseAddr(share.TunGateway4)
	if err := netlink.AddrAdd(tunnel, address); err != nil || netlink.LinkSetUp(tunnel) != nil {
		t.Fatal(err)
	}
	if err := network.install(nil); err != nil {
		t.Fatal(err)
	}
	// The killed worker's device goes with it; the rule, table and record stay.
	records := t.TempDir()
	if err := network.record(records); err != nil {
		t.Fatal(err)
	}
	if err := netlink.LinkDel(tunnel); err != nil {
		t.Fatal(err)
	}
	if !linuxGuardLeft() {
		t.Fatal("the killed tunnel's guard was not reported")
	}
	live := exec.Command("sh", "-c", "sleep 30; true", "--linux-supervisor")
	if err := live.Start(); err != nil {
		t.Fatal(err)
	}
	reported := linuxGuardLeft()
	live.Process.Kill()
	live.Wait()
	if reported {
		t.Fatal("a running supervisor's guard was reported")
	}
	reapLinuxNetworks(records, linuxNetwork.cleanup)
	if linuxGuardLeft() {
		t.Fatal("the clear left the guard")
	}
	if exec.Command(linuxTool("nft"), "list", "table", "inet", network.Name).Run() == nil {
		t.Fatal("the clear left the DNS redirect")
	}
}

func TestLinuxReapsOnlyNetworksOfDeadSupervisors(t *testing.T) {
	directory := t.TempDir()
	// The trailing argument becomes $0, giving the shell a supervisor command line.
	live := exec.Command("sh", "-c", "sleep 30; true", "--linux-supervisor")
	if err := live.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { live.Process.Kill(); live.Wait() }()
	dead := exec.Command("sh", "-c", "true", "--linux-supervisor")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	write := func(name string, record linuxNetworkRecord) {
		data, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(directory+"/"+name, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	network := func(name string) linuxNetwork {
		return linuxNetwork{Name: name, Table: 12001, Priority: 12001, Mark: 0x52562ee1, DNSPort: 35123}
	}
	write("rv000000000001.json", linuxNetworkRecord{network("rv000000000001"), live.Process.Pid})
	write("rv000000000002.json", linuxNetworkRecord{network("rv000000000002"), dead.Process.Pid})
	write("rv00000000000x.json", linuxNetworkRecord{network("rv00000000000x"), dead.Process.Pid})
	var released []string
	reapLinuxNetworks(directory, func(network linuxNetwork) error {
		released = append(released, network.Name)
		return nil
	})
	if !reflect.DeepEqual(released, []string{"rv000000000002"}) {
		// LNX-1 failed here once in a full container run; say which supervisor looked wrong.
		cmdline := func(pid int) string {
			data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
			return fmt.Sprintf("%q (%v)", data, err)
		}
		t.Fatalf("released %v; live %d: %s; dead %d: %s", released,
			live.Process.Pid, cmdline(live.Process.Pid), dead.Process.Pid, cmdline(dead.Process.Pid))
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 || entries[0].Name() != "rv000000000001.json" {
		t.Fatalf("remaining records: %v %v", entries, err)
	}
}

func TestLinuxIgnoresWindowsIconWorkaroundWithoutMutatingSettings(t *testing.T) {
	policy := &share.WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0", "::/0"}, HideVPNIcon: true}
	routes, err := share.WindowsRoutes(linuxPolicy(policy))
	if err != nil {
		t.Fatal(err)
	}
	got := []string{}
	for _, route := range routes {
		got = append(got, route.String())
	}
	if !reflect.DeepEqual(got, []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}) || !policy.HideVPNIcon {
		t.Fatalf("Linux routes/settings: %v %+v", got, policy)
	}
}

func TestLinuxProbeCannotCreateTunnelOrUsePrivilegedFiles(t *testing.T) {
	httpFixture := `{"log":{"loglevel":"none"},"inbounds":[{"protocol":"http","listen":"127.0.0.1","port":18091}],"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["198.18.77.2/32","2001:db8:77::2/128","192.0.2.2/32"]}]}}]}`
	httpConfig, err := linuxProbeConfig(httpFixture)
	if err != nil {
		t.Fatal("HTTP probe graph: ", err)
	}
	var httpGraph struct{ Inbounds []struct{ Protocol string } }
	if json.Unmarshal([]byte(httpConfig), &httpGraph) != nil || len(httpGraph.Inbounds) != 1 || httpGraph.Inbounds[0].Protocol != "http" {
		t.Fatal("HTTP probe gained a validation-only listener")
	}
	fixture := `{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":10890}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}`
	encoded, err := linuxProbeConfig(fixture)
	if err != nil {
		t.Fatal(err)
	}
	var config struct{ Inbounds []struct{ Protocol string } }
	if json.Unmarshal([]byte(encoded), &config) != nil || len(config.Inbounds) != 1 || config.Inbounds[0].Protocol != "socks" {
		t.Fatal("probe acquired extra listeners")
	}
	for _, raw := range []string{
		linuxConfigFixture,
		`{"inbounds":[{"protocol":"socks","listen":"0.0.0.0","port":10890}],"outbounds":[{"protocol":"freedom"}]}`,
		`{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":10890}],"outbounds":[{"protocol":"vless","streamSettings":{"tlsSettings":{"certificates":[{"keyFile":"/root/private"}]}}}]}`,
	} {
		if _, err := linuxProbeConfig(raw); err == nil {
			t.Fatal("unsafe probe accepted")
		}
	}
}

func TestLinuxFramingRejectsUnknownTrailingAndOversizedInput(t *testing.T) {
	for _, raw := range []string{`{"ready":true,"extra":true}`, `{"ready":true} {"ready":false}`} {
		var buffer bytes.Buffer
		_ = binary.Write(&buffer, binary.LittleEndian, uint32(len(raw)))
		buffer.WriteString(raw)
		var reply linuxReply
		if linuxReadFrame(&buffer, &reply) == nil {
			t.Fatal("ambiguous privileged frame accepted")
		}
	}
	for _, length := range []uint32{0, maxMessage + 1} {
		var buffer bytes.Buffer
		_ = binary.Write(&buffer, binary.LittleEndian, length)
		var reply linuxReply
		if linuxReadFrame(&buffer, &reply) == nil {
			t.Fatal("invalid frame size accepted")
		}
	}
	var buffer bytes.Buffer
	source := linuxCommand{Action: "start", assets: map[string][]byte{"geoip.dat": {1, 2, 3}, "geosite.dat": {4, 5}}}
	if linuxWriteCommand(&buffer, source) != nil {
		t.Fatal("write failed")
	}
	got, err := linuxReadCommand(&buffer)
	if err != nil || !reflect.DeepEqual(got.assets, source.assets) {
		t.Fatal("assets did not cross private pipe intact", err)
	}
	if _, err := io.ReadAll(&buffer); err != nil {
		t.Fatal(err)
	}
}

func TestLinuxChildOwnerEOFReapsProcess(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^TestLinuxChildFixture$")
	command.Env = append(os.Environ(), "ELARNI_LINUX_CHILD_FIXTURE=1")
	child, err := startLinuxChild(command, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer child.stop()
	reply, err := child.request(linuxCommand{Action: "start"}, 3*time.Second)
	if err != nil || !reply.Ready {
		t.Fatal("fixture did not start", err)
	}
	if child.stop() != nil {
		t.Fatal("child survived owner EOF")
	}
	select {
	case <-child.done:
	case <-time.After(time.Second):
		t.Fatal("unreaped child")
	}
}
func TestLinuxChildFixture(t *testing.T) {
	if os.Getenv("ELARNI_LINUX_CHILD_FIXTURE") != "1" {
		return
	}
	if _, err := linuxReadCommand(os.Stdin); err != nil {
		os.Exit(2)
	}
	if linuxWriteFrame(os.Stdout, linuxReply{Ready: true}) != nil {
		os.Exit(3)
	}
	_, err := linuxReadCommand(os.Stdin)
	if err == nil {
		os.Exit(4)
	}
	os.Exit(0)
}

// Regression: a failed nft delete left the DNS redirect, but cleanup still deleted
// every rule, so staleVPNGuard reported nothing and lookups stayed broken.
func TestLinuxCleanupKeepsTheMarkerWhileTheRedirectMayRemain(t *testing.T) {
	network := linuxNetwork{Name: "rv0123456789ab", Table: 12001, Priority: 12001, Mark: 0x52562ee1}
	other := linuxNetwork{Name: "rv0123456789cd", Table: 12002, Priority: 12002, Mark: 0x52562ee2}
	marker, policy := *network.markerRule(netlink.FAMILY_V4), *network.rule(netlink.FAMILY_V6)
	foreign := *network.rule(netlink.FAMILY_V4)
	foreign.Protocol = 0
	rules := []netlink.Rule{marker, policy, *other.markerRule(netlink.FAMILY_V4), foreign}
	if got := network.staleRules(rules, false); !reflect.DeepEqual(got, []netlink.Rule{marker, policy}) {
		t.Fatalf("a full cleanup deletes %v", got)
	}
	if got := network.staleRules(rules, true); !reflect.DeepEqual(got, []netlink.Rule{policy}) {
		t.Fatalf("with the redirect left, cleanup deletes %v", got)
	}
}

// The Linux C1 producer compares the route marked sockets take; the lookup must work
// with a mark, without privileges, or route moves are never noticed.
func TestLinuxPhysicalPathFollowsTheMarkedRoute(t *testing.T) {
	routes, err := netlink.RouteGet(net.ParseIP("192.0.2.1"))
	if err != nil || len(routes) == 0 {
		t.Skip("no IPv4 route on this host:", err)
	}
	path := linuxPhysicalPath(0x52562ee1) // no rule matches the mark, so the main table answers
	if want := (linuxRoute{routes[0].LinkIndex, routes[0].Gw.String(), routes[0].Src.String()}); path[0] != want || want.link == 0 {
		t.Fatalf("marked path %+v, want %+v", path[0], want)
	}
}
