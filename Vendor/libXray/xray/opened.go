package xray

import (
	"encoding/json"
	"net/netip"
	"os"
	"slices"
	"strings"

	"github.com/xtls/xray-core/app/dispatcher"
	"github.com/xtls/xray-core/app/router"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
)

// Elarni: a listed app that was running before the tunnel started may keep connections that
// skip per-app routing: Windows keeps a connection on the network it opened it on. After the
// tunnel is up, its owner asks the core to reset them, so the app reconnects through the tunnel,
// and the connections view lists them, with those this system would not reset.

// perAppRule is one listed rule of the per-app gate: the router tries them in order, own rules
// before "children:" rules, and the first that matches a program decides where its traffic goes.
type perAppRule struct {
	processes []string
	tunnel    bool // its target is not a direct (freedom) outbound, so the tunnel takes the traffic
}

// perAppRules returns the listed rules of the per-app gate in the router's order.
func perAppRules(configJSON string) []perAppRule {
	var config struct {
		Outbounds []struct{ Tag, Protocol string } `json:"outbounds"`
		Routing   struct {
			Rules []struct {
				RuleTag     string   `json:"ruleTag"`
				OutboundTag string   `json:"outboundTag"`
				Process     []string `json:"process"`
			} `json:"rules"`
		} `json:"routing"`
	}
	if json.Unmarshal([]byte(configJSON), &config) != nil {
		return nil
	}
	direct := map[string]bool{}
	for _, outbound := range config.Outbounds {
		if outbound.Protocol == "freedom" {
			direct[outbound.Tag] = true
		}
	}
	var rules []perAppRule
	for _, rule := range config.Routing.Rules {
		if strings.HasPrefix(rule.RuleTag, "elarni-per-app-listed-") && len(rule.Process) > 0 {
			rules = append(rules, perAppRule{processes: rule.Process, tunnel: !direct[rule.OutboundTag]})
		}
	}
	return rules
}

// perAppTunnel tells which programs the per-app gate sends into the tunnel.
type perAppTunnel struct {
	rules    []perAppRule
	matchers []*router.ProcessNameMatcher
}

func newPerAppTunnel(rules []perAppRule) *perAppTunnel {
	tunnel := &perAppTunnel{rules: rules}
	for _, rule := range rules {
		tunnel.matchers = append(tunnel.matchers, router.NewProcessNameMatcher(rule.processes))
	}
	return tunnel
}

// takes reports whether the first listed rule that matches the program sends it into the tunnel.
func (t *perAppTunnel) takes(process xnet.Process) bool {
	for i, matcher := range t.matchers {
		if matcher.MatchesProcess(process.PID, process.Name, process.Path) {
			return t.rules[i].tunnel
		}
	}
	return false
}

// tunnelRules are the running core's perAppRules.
var tunnelRules []perAppRule

var sharedAddressSpace = netip.MustParsePrefix("100.64.0.0/10")

// outsideTunnel reports whether a connection skips the tunnel to another network: it is not
// from the tunnel's own addresses, and not to this computer or a local network (private,
// link-local or carrier-grade NAT addresses, as Tailscale uses), which keep their route.
var outsideTunnel = func(connection xnet.TCPConnection, tunnel []netip.Prefix) bool {
	local, remote := connection.Local.Addr().Unmap(), connection.Remote.Addr().Unmap()
	for _, prefix := range tunnel {
		if prefix.Contains(local) {
			return false
		}
	}
	return !local.IsLoopback() && remote.IsGlobalUnicast() && !remote.IsPrivate() && !sharedAddressSpace.Contains(remote)
}

// MoveOpenedConnections resets the listed apps' TCP connections that were open before this core
// started and run outside the tunnel, whose addresses tunnel holds, and lists them in the recent
// connections: reset, or kept where this system does not let the core reset them.
func MoveOpenedConnections(tunnel []netip.Prefix) (reset, kept int) {
	coreServerMu.Lock()
	server, rules := coreServer, tunnelRules
	coreServerMu.Unlock()
	if server == nil || !slices.ContainsFunc(rules, func(rule perAppRule) bool { return rule.tunnel }) {
		return 0, 0
	}
	connections, err := xnet.EstablishedTCPConnections()
	if err != nil || len(connections) == 0 {
		return 0, 0
	}
	listed, err := xnet.ListProcesses()
	if err != nil {
		return 0, 0
	}
	processes := make(map[int]xnet.Process, len(listed))
	for _, process := range listed {
		processes[process.PID] = process
	}
	gate := newPerAppTunnel(rules)
	matches := map[int]bool{}
	self := os.Getpid()
	var entries []dispatcher.RecentConnection
	for _, connection := range connections {
		process, ok := processes[connection.PID]
		if !ok || connection.PID == self || !outsideTunnel(connection, tunnel) {
			continue
		}
		matched, seen := matches[connection.PID]
		if !seen {
			matched = gate.takes(process)
			matches[connection.PID] = matched
		}
		if !matched {
			continue
		}
		entry := dispatcher.RecentConnection{Network: "tcp", Host: connection.Remote.Addr().Unmap().String(),
			Port: connection.Remote.Port(), Owner: "found", PID: process.PID, Name: process.Name, Path: process.Path, Before: "reset"}
		if xnet.ResetTCPConnection(connection) != nil {
			entry.Before = "kept"
			kept++
		} else {
			reset++
		}
		entries = append(entries, entry)
	}
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == server {
		if recent, ok := server.GetFeature(routing.DispatcherType()).(*dispatcher.DefaultDispatcher); ok {
			recent.NoteOpenedBefore(entries)
		}
	}
	return reset, kept
}
