//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netlink/nl"
	"github.com/xtls/libxray/share"
	"golang.org/x/sys/unix"
)

type linuxNetwork struct {
	Name     string `json:"name"`
	Table    int    `json:"table"`
	Priority int    `json:"priority"`
	Mark     uint32 `json:"mark"`
	DNSPort  int    `json:"dnsPort"`
	NoIPv6   bool   `json:"noIPv6,omitempty"`
}

// Records outlive both root processes, so the next supervisor can reap a table
// whose DNS redirect would otherwise break name resolution after a SIGKILL.
const linuxNetworkRecords = "/run/elarni-vpn"

// linuxVPNLock admits one tunnel per machine across users and the system
// service. It sits outside linuxNetworkRecords, whose reaper deletes other files.
const linuxVPNLock = "/run/elarni-vpn.lock"

// acquireLinuxVPNLock holds the lock until the file is closed; the kernel drops
// it if the supervisor dies.
func acquireLinuxVPNLock(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, errors.New("vpn_resources_failed")
	}
	if unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB) != nil {
		unix.Close(fd)
		return nil, errors.New("vpn_guard_busy")
	}
	return os.NewFile(uintptr(fd), path), nil
}

type linuxNetworkRecord struct {
	linuxNetwork
	PID int `json:"pid"`
}

// valid rejects identities that must never reach netlink or nft's input language.
func (network linuxNetwork) valid() bool {
	if len(network.Name) != 14 || network.Name[:2] != "rv" || network.Table < 12000 || network.Table >= 28000 || network.Priority != network.Table || network.DNSPort < 1024 || network.DNSPort > 65535 || network.Mark == 0 {
		return false
	}
	_, err := hex.DecodeString(network.Name[2:])
	return err == nil
}

func (network linuxNetwork) families() []int {
	if network.NoIPv6 {
		return []int{netlink.FAMILY_V4}
	}
	return []int{netlink.FAMILY_V4, netlink.FAMILY_V6}
}

// linuxIPv6 reports whether a new interface can take IPv6 addresses. It cannot
// after ipv6.disable=1 or net.ipv6.conf.default.disable_ipv6=1.
func linuxIPv6() bool {
	value, err := os.ReadFile("/proc/sys/net/ipv6/conf/default/disable_ipv6")
	return err == nil && strings.TrimSpace(string(value)) == "0"
}

func (network linuxNetwork) record(directory string) error {
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(linuxNetworkRecord{linuxNetwork: network, PID: os.Getpid()})
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, network.Name+".json"), data, 0o600)
}

func (network linuxNetwork) forget(directory string) {
	_ = os.Remove(filepath.Join(directory, network.Name+".json"))
}

func linuxSupervisorAlive(pid int) bool {
	cmdline, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	return err == nil && bytes.Contains(cmdline, []byte("\x00--linux-supervisor"))
}

// reapLinuxNetworks releases recorded resources whose supervisor has died.
func reapLinuxNetworks(directory string, release func(linuxNetwork) error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return
	}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		var record linuxNetworkRecord
		data, err := os.ReadFile(path)
		if err != nil || json.Unmarshal(data, &record) != nil || !record.valid() || entry.Name() != record.Name+".json" {
			_ = os.Remove(path)
			continue
		}
		if !linuxSupervisorAlive(record.PID) && release(record.linuxNetwork) == nil {
			_ = os.Remove(path)
		}
	}
}

// linuxGuardLeft reports, without root, whether a tunnel's policy rule outlived
// every supervisor. Its DNS redirect then sends all lookups to a dead listener,
// route planning's included, until a helper reaps it.
func linuxGuardLeft() bool {
	for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		rules, err := netlink.RuleList(family)
		if err != nil {
			continue
		}
		for _, rule := range rules {
			if rule.Protocol == 186 && rule.Table >= 12000 && rule.Table < 28000 {
				return !linuxSupervisorRunning()
			}
		}
	}
	return false
}

// linuxSupervisorRunning treats an unreadable /proc as a live supervisor, so
// nothing asks for consent it may not need.
func linuxSupervisorRunning() bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return true
	}
	for _, entry := range entries {
		if pid, err := strconv.Atoi(entry.Name()); err == nil && linuxSupervisorAlive(pid) {
			return true
		}
	}
	return false
}

func linuxPolicy(policy *share.WindowsRoutePolicy) *share.WindowsRoutePolicy {
	if policy == nil {
		return nil
	}
	copy := *policy
	copy.HideVPNIcon = false // Linux has no hide-icon route workaround.
	return &copy
}

func linuxTunnelConfig(raw []byte, network linuxNetwork, policy *share.WindowsRoutePolicy) ([]byte, error) {
	validated, err := share.WindowsTunnelConfig(raw, network.Name, linuxPolicy(policy))
	if err != nil {
		return nil, err
	}
	var config map[string]any
	if json.Unmarshal(validated, &config) != nil {
		return nil, errors.New("invalid_vpn_config")
	}
	outbounds := config["outbounds"].([]any)
	for i, entry := range outbounds {
		outbound := entry.(map[string]any)
		if outbound["tag"] == "elarni-linux-dns" {
			return nil, errors.New("invalid_vpn_config")
		}
		if i == len(outbounds)-1 {
			outbound["tag"] = "elarni-linux-dns"
		}
	}
	inbounds := config["inbounds"].([]any)
	settings := inbounds[0].(map[string]any)["settings"].(map[string]any)
	settings["autoSystemRoutingTable"] = []string{} // Only the owned policy table captures traffic.
	dnsAddresses := []string{"127.0.0.1", "::1"}
	dnsTags := []string{"elarni-tun", "elarni-linux-dns0", "elarni-linux-dns1"}
	if network.NoIPv6 {
		// The kernel refuses IPv6 addresses and listeners; IPv4 still works.
		for _, key := range []string{"gateway", "dns"} {
			values, _ := settings[key].([]any)
			kept := []any{}
			for _, value := range values {
				if address, _ := value.(string); !strings.Contains(address, ":") {
					kept = append(kept, value)
				}
			}
			settings[key] = kept
		}
		dnsAddresses, dnsTags = dnsAddresses[:1], dnsTags[:2]
	}
	for i, address := range dnsAddresses {
		inbounds = append(inbounds, map[string]any{"tag": fmt.Sprintf("elarni-linux-dns%d", i), "protocol": "dokodemo-door", "listen": address,
			"port": network.DNSPort, "settings": map[string]any{"address": share.TunDNS4, "port": 53, "network": "tcp,udp"}})
	}
	config["inbounds"] = inbounds
	rules := config["routing"].(map[string]any)["rules"].([]any)
	dnsRule := rules[0].(map[string]any)
	dnsRule["outboundTag"] = "elarni-linux-dns"
	dnsRule["inboundTag"] = dnsTags
	return json.Marshal(config)
}

var errLinuxFirewallUnavailable = errors.New("vpn_firewall_unavailable")

func nft(script string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, linuxTool("nft"), "-f", "-")
	command.Stdin = strings.NewReader(script)
	if err := command.Run(); err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) && ctx.Err() == nil {
			return errLinuxFirewallUnavailable // nftables is not installed
		}
		return errors.New("vpn_firewall_failed")
	}
	return nil
}

// The supervisor reserves an empty private firewall table before starting a
// worker. Both processes know the exact resources to reap after either dies.
func reserveLinuxNetwork() (linuxNetwork, error) {
	for attempt := 0; attempt < 32; attempt++ {
		var random [8]byte
		if _, err := rand.Read(random[:]); err != nil {
			return linuxNetwork{}, err
		}
		network := linuxNetwork{Name: "rv" + hex.EncodeToString(random[:6]), Table: 12000 + int(binary.LittleEndian.Uint16(random[6:]))%16000}
		network.Priority = network.Table
		network.Mark = 0x52560000 | uint32(network.Table)
		network.NoIPv6 = !linuxIPv6()
		if _, err := net.InterfaceByName(network.Name); err == nil {
			continue
		}
		occupied := false
		for _, family := range network.families() {
			rules, err := netlink.RuleList(family)
			if err != nil {
				return linuxNetwork{}, errors.New("vpn_routes_failed")
			}
			if !network.free(rules) {
				occupied = true
			}
			routes, err := netlink.RouteListFiltered(family, &netlink.Route{Table: network.Table}, netlink.RT_FILTER_TABLE)
			if err != nil {
				return linuxNetwork{}, errors.New("vpn_routes_failed")
			}
			if len(routes) != 0 {
				occupied = true
			}
		}
		if occupied {
			continue
		}
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			return linuxNetwork{}, errors.New("vpn_dns_failed")
		}
		network.DNSPort = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
		if err := nft("create table inet " + network.Name + "\n"); err != nil {
			if errors.Is(err, errLinuxFirewallUnavailable) {
				return linuxNetwork{}, err
			}
			continue
		}
		return network, nil
	}
	return linuxNetwork{}, errors.New("vpn_resources_busy")
}

// free reports that no rule uses this network's table or sits within a band of its
// priority, on either side. Every network has a rule at its own priority, so the bands
// of two networks never overlap and staleRules can tell them apart by priority.
func (network linuxNetwork) free(rules []netlink.Rule) bool {
	for _, rule := range rules {
		if rule.Table == network.Table || rule.Priority > network.Priority-linuxRulePriorities && rule.Priority < network.Priority+linuxRulePriorities {
			return false
		}
	}
	return true
}

func (network linuxNetwork) rule(family int) *netlink.Rule {
	rule := netlink.NewRule()
	rule.Family, rule.Priority, rule.Table = family, network.Priority, network.Table
	rule.Mark = network.Mark
	mask := uint32(0xffffffff)
	rule.Mask = &mask
	rule.Invert = true
	rule.Protocol = 186
	return rule
}

// linuxRulePriorities bounds policyRules: two for each of the 129 IPv6 prefix lengths.
const linuxRulePriorities = 258

// policyRules send unmarked traffic into the tunnel table. As on Windows, and on
// macOS unless routes are enforced or include all networks, a longer physical
// route (a LAN, a container bridge) wins: before the tunnel's routes of each
// length, the main table answers with any longer route of its own.
func (network linuxNetwork) policyRules(family int, routes []netip.Prefix, policy *share.WindowsRoutePolicy) []*netlink.Rule {
	rules := []*netlink.Rule{network.rule(family)}
	if policy != nil && (policy.EnforceRoutes || policy.IncludeAllNetworks) {
		return rules
	}
	lengths := map[int]bool{}
	for _, prefix := range routes {
		if prefix.Addr().Is4() == (family == netlink.FAMILY_V4) {
			lengths[prefix.Bits()] = true
		}
	}
	priority := network.Priority
	for i, length := range slices.Sorted(maps.Keys(lengths)) {
		if i > 0 {
			priority--
			tunnel := network.rule(family)
			tunnel.Priority, tunnel.SuppressPrefixlen = priority, length-1
			rules = append(rules, tunnel)
		}
		priority--
		physical := network.rule(family)
		physical.Priority, physical.Table, physical.SuppressPrefixlen = priority, unix.RT_TABLE_MAIN, length
		rules = append(rules, physical)
	}
	return rules
}

// addRule installs a policyRules rule. netlink v1.3.1 drops suppress_prefixlength
// for tables above 255, so those rules are encoded here.
func addRule(rule *netlink.Rule) error {
	if rule.Table < 256 || rule.SuppressPrefixlen < 0 {
		return netlink.RuleAdd(rule)
	}
	request := nl.NewNetlinkRequest(unix.RTM_NEWRULE, unix.NLM_F_CREATE|unix.NLM_F_EXCL|unix.NLM_F_ACK)
	message := nl.NewRtMsg()
	message.Family, message.Type, message.Flags = uint8(rule.Family), unix.FR_ACT_TO_TBL, netlink.FibRuleInvert
	request.AddData(message)
	for _, attribute := range [][2]uint32{{unix.FRA_PRIORITY, uint32(rule.Priority)}, {unix.FRA_FWMARK, rule.Mark}, {unix.FRA_FWMASK, *rule.Mask}, {unix.FRA_TABLE, uint32(rule.Table)}, {unix.FRA_SUPPRESS_PREFIXLEN, uint32(rule.SuppressPrefixlen)}} {
		request.AddData(nl.NewRtAttr(int(attribute[0]), nl.Uint32Attr(attribute[1])))
	}
	request.AddData(nl.NewRtAttr(unix.FRA_PROTOCOL, nl.Uint8Attr(rule.Protocol)))
	_, err := request.Execute(unix.NETLINK_ROUTE, 0)
	return err
}

func (network linuxNetwork) install(policy *share.WindowsRoutePolicy) error {
	routes, err := share.WindowsRoutes(linuxPolicy(policy))
	if err != nil {
		return err
	}
	link, err := netlink.LinkByName(network.Name)
	if err != nil {
		return errors.New("vpn_adapter_failed")
	}
	for _, prefix := range routes {
		family := netlink.FAMILY_V6
		if prefix.Addr().Is4() {
			family = netlink.FAMILY_V4
		} else if network.NoIPv6 {
			continue
		}
		_, destination, _ := net.ParseCIDR(prefix.String())
		route := netlink.Route{LinkIndex: link.Attrs().Index, Dst: destination, Table: network.Table, Family: family, Protocol: 186, Scope: netlink.SCOPE_LINK}
		if netlink.RouteAdd(&route) != nil {
			return errors.New("vpn_routes_failed")
		}
	}
	protected, err := linuxGuardedRoutes(network, policy)
	if err != nil {
		return err
	}
	// An unprivileged linuxGuardLeft sees only rules, so a marker rule goes first: it names an
	// interface that doesn't exist and matches no packet. The guard and DNS redirect then go in
	// before any rule routes traffic into the tunnel, so a start that fails or is killed between
	// them leaves no traffic routed past a missing guard, and is still reported.
	for _, family := range network.families() {
		if addRule(network.markerRule(family)) != nil {
			return errors.New("vpn_routes_failed")
		}
	}
	if err := nft(network.firewall(protected)); err != nil {
		return err
	}
	for _, family := range network.families() {
		for _, rule := range network.policyRules(family, routes, policy) {
			if addRule(rule) != nil {
				return errors.New("vpn_routes_failed")
			}
		}
	}
	return nil
}

// markerRule carries this network's mark, so cleanup removes it, and matches only packets
// that arrive on a device name no link has.
func (network linuxNetwork) markerRule(family int) *netlink.Rule {
	rule := network.rule(family)
	rule.Invert, rule.IifName = false, network.Name+"m"
	return rule
}

// linuxGuardedRoutes lists destinations the guard rejects outside the tunnel.
// A tunnel without IPv6 rejects its IPv6 routes instead of leaking them.
func linuxGuardedRoutes(network linuxNetwork, policy *share.WindowsRoutePolicy) ([]netip.Prefix, error) {
	policy = linuxPolicy(policy)
	protected, err := share.WindowsProtectedRoutes(policy)
	if err != nil || !network.NoIPv6 {
		return protected, err
	}
	routes, err := share.WindowsRoutes(policy)
	if err != nil {
		return nil, err
	}
	var guarded, ipv6 []netip.Prefix
	for _, prefix := range protected {
		if prefix.Addr().Is4() {
			guarded = append(guarded, prefix)
		}
	}
	for _, prefix := range routes {
		if !prefix.Addr().Is4() {
			ipv6 = append(ipv6, prefix)
		}
	}
	ipv6, err = share.ProtectedPrefixes(ipv6)
	return append(guarded, ipv6...), err
}

func (network linuxNetwork) firewall(protected []netip.Prefix) string {
	name := network.Name
	var script strings.Builder
	fmt.Fprintf(&script, "add chain inet %s dns { type nat hook output priority -100; policy accept; }\n", name)
	fmt.Fprintf(&script, "add rule inet %s dns meta mark %d return\n", name, network.Mark)
	// Marked bootstrap lookups can use the OS stub. Its upstream requests must
	// remain physical; ordinary applications are intercepted before reaching it.
	if account, err := user.Lookup("systemd-resolve"); err == nil {
		if uid, err := strconv.ParseUint(account.Uid, 10, 32); err == nil {
			fmt.Fprintf(&script, "add rule inet %s dns meta skuid %d return\n", name, uid)
		}
	}
	fmt.Fprintf(&script, "add rule inet %s dns meta l4proto { tcp, udp } th dport 53 redirect to :%d\n", name, network.DNSPort)
	if len(protected) != 0 {
		fmt.Fprintf(&script, "add chain inet %s guard { type filter hook output priority 0; policy accept; }\n", name)
		fmt.Fprintf(&script, "add rule inet %s guard meta mark %d return\n", name, network.Mark)
		// DNS redirection can retain the tunnel's local source address. Replies
		// to local sockets must not be rejected by the physical-route guard.
		fmt.Fprintf(&script, "add rule inet %s guard oifname \"lo\" return\n", name)
		fmt.Fprintf(&script, "add rule inet %s guard oifname %q return\n", name, name)
		// Forwarded container/VM traffic follows the same policy rule; reject it
		// too when it would leave outside the tunnel.
		fmt.Fprintf(&script, "add chain inet %s forward_guard { type filter hook forward priority 0; policy accept; }\n", name)
		fmt.Fprintf(&script, "add rule inet %s forward_guard oifname %q return\n", name, name)
		for _, ipv4 := range []bool{true, false} {
			prefixes := []string{}
			for _, prefix := range protected {
				if prefix.Addr().Is4() == ipv4 {
					prefixes = append(prefixes, prefix.String())
				}
			}
			if len(prefixes) == 0 {
				continue
			}
			family, set := "ip6", "protected6"
			if ipv4 {
				family, set = "ip", "protected4"
			}
			kind := "ipv6_addr"
			if ipv4 {
				kind = "ipv4_addr"
			}
			fmt.Fprintf(&script, "add set inet %s %s { type %s; flags interval; elements = { %s }; }\n", name, set, kind, strings.Join(prefixes, ", "))
			fmt.Fprintf(&script, "add rule inet %s guard %s daddr @%s reject\n", name, family, set)
			fmt.Fprintf(&script, "add rule inet %s forward_guard %s daddr @%s reject\n", name, family, set)
		}
	}
	return script.String()
}

func (network linuxNetwork) cleanup() error {
	var failures []error
	// Remove interception before removing its DNS listener or tunnel.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	listed := exec.CommandContext(ctx, linuxTool("nft"), "list", "table", "inet", network.Name).Run()
	// A listing that timed out may hide the table.
	present := listed == nil || errors.Is(ctx.Err(), context.DeadlineExceeded)
	cancel()
	redirect := false
	if present {
		if err := nft("delete table inet " + network.Name + "\n"); err != nil {
			failures = append(failures, err)
			redirect = true
		}
	}

	for _, family := range network.families() {
		rules, err := netlink.RuleList(family)
		if err != nil {
			failures = append(failures, err)
		}
		for _, rule := range network.staleRules(rules, redirect) {
			if err := netlink.RuleDel(&rule); err != nil && !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.ESRCH) {
				failures = append(failures, err)
			}
		}
		routes, err := netlink.RouteListFiltered(family, &netlink.Route{Table: network.Table, Protocol: 186}, netlink.RT_FILTER_TABLE|netlink.RT_FILTER_PROTOCOL)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		for _, route := range routes {
			if err := netlink.RouteDel(&route); err != nil && !errors.Is(err, unix.ESRCH) {
				failures = append(failures, err)
			}
		}
	}
	return errors.Join(failures...)
}

// staleRules are this network's rules to delete; the mark and its priorities name them
// whatever policy installed them. A supervisor's networks share its mark, and during a
// restart the old one is cleaned up beside the new one. While its DNS redirect may
// remain, the marker rule stays, so an unprivileged linuxGuardLeft still reports the
// leftover and Repair can clear it.
func (network linuxNetwork) staleRules(rules []netlink.Rule, redirect bool) []netlink.Rule {
	var stale []netlink.Rule
	for _, rule := range rules {
		if rule.Protocol == 186 && rule.Mark == network.Mark && rule.Priority > network.Priority-linuxRulePriorities && rule.Priority <= network.Priority &&
			(!redirect || rule.IifName != network.markerRule(rule.Family).IifName) {
			stale = append(stale, rule)
		}
	}
	return stale
}

func linuxMarkControl(mark uint32) func(string, string, syscall.RawConn) error {
	return func(_, _ string, raw syscall.RawConn) error {
		var result error
		if err := raw.Control(func(fd uintptr) { result = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(mark)) }); err != nil {
			return err
		}
		return result
	}
}

func decodeLinuxJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(target) != nil {
		return errors.New("invalid_request")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("invalid_request")
	}
	return nil
}
