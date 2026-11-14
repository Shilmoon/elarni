package xray

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
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
// and the connections view lists them, with those this system would not reset. On Windows the
// same holds for every program: a connection opened before the tunnel, or between two tunnels,
// runs outside it for as long as it lives, so the core resets those too.

// perAppRule is one listed rule of the per-app gate: the router tries them in order, own rules
// before "children:" rules, and the first that matches a program decides where its traffic goes.
type perAppRule struct {
	processes []string
	tunnel    bool // its target is not a direct (freedom) outbound, so the tunnel takes the traffic
}

// perAppGate returns the listed rules of the per-app gate in the router's order, and whether the
// tunnel takes a program none of them matches: it does unless the gate sends the other programs
// direct.
func perAppGate(configJSON string) (rules []perAppRule, rest bool) {
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
		return nil, true
	}
	direct := map[string]bool{}
	for _, outbound := range config.Outbounds {
		if outbound.Protocol == "freedom" {
			direct[outbound.Tag] = true
		}
	}
	rest = true
	for _, rule := range config.Routing.Rules {
		if strings.HasPrefix(rule.RuleTag, "elarni-per-app-listed-") && len(rule.Process) > 0 {
			rules = append(rules, perAppRule{processes: rule.Process, tunnel: !direct[rule.OutboundTag]})
		} else if rule.RuleTag == "elarni-per-app-other" {
			rest = !direct[rule.OutboundTag]
		}
	}
	return rules, rest
}

// perAppTunnel tells which programs the per-app gate sends into the tunnel.
type perAppTunnel struct {
	rules    []perAppRule
	matchers []*router.ProcessNameMatcher
	rest     bool // where a program goes that no listed rule matches
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
	tunnel, listed := t.decides(process)
	return tunnel && listed
}

// decides reports whether the tunnel takes the program's traffic, and whether a listed rule says so.
func (t *perAppTunnel) decides(process xnet.Process) (tunnel, listed bool) {
	for i, matcher := range t.matchers {
		if matcher.MatchesProcess(process.PID, process.Name, process.Path) {
			return t.rules[i].tunnel, true
		}
	}
	return t.rest, false
}

// tunnelRules and tunnelRest are the running core's perAppGate; keptOpened holds the
// connections it listed as kept, which a later pass leaves out.
var (
	tunnelRules []perAppRule
	tunnelRest  bool
	keptOpened  map[xnet.TCPConnection]struct{}
)

var sharedAddressSpace = netip.MustParsePrefix("100.64.0.0/10")

// outsideTunnel reports whether a connection skips the tunnel to another network: it is not
// from the tunnel's own addresses, and not to this computer or a local network (private,
// link-local or carrier-grade NAT addresses, as Tailscale uses), which keep their route. With
// routed, the system's routes tell which remote addresses the tunnel takes, a private one
// among them, so the caller asks those instead.
var outsideTunnel = func(connection xnet.TCPConnection, tunnel []netip.Prefix, routed bool) bool {
	local, remote := connection.Local.Addr().Unmap(), connection.Remote.Addr().Unmap()
	for _, prefix := range tunnel {
		if prefix.Contains(local) {
			return false
		}
	}
	if local.IsLoopback() || remote.IsLoopback() {
		return false
	}
	return routed || remote.IsGlobalUnicast() && !remote.IsPrivate() && !sharedAddressSpace.Contains(remote)
}

// MoveOpenedConnections resets the listed apps' TCP connections that were open before this core
// started and run outside the tunnel, whose addresses tunnel holds, and lists them in the recent
// connections: reset, or kept where this system does not let the core reset them.
//
// routed is for a system that keeps a connection on the network it was opened on (Windows): it
// tells whether the system now routes an address into the tunnel. With it, the connections to
// those addresses are reset for every program the tunnel takes, listed or not, and only those:
// one to an excluded route keeps its way. They are not listed unless a listed app owns them, and
// this program's other processes keep theirs, which they bind to the physical network.
func MoveOpenedConnections(tunnel []netip.Prefix, routed func(netip.Addr) bool) (reset, kept int) {
	coreServerMu.Lock()
	server, rules, rest := coreServer, tunnelRules, tunnelRest
	coreServerMu.Unlock()
	everyProgram := routed != nil && rest
	if server == nil || !everyProgram && !slices.ContainsFunc(rules, func(rule perAppRule) bool { return rule.tunnel }) {
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
	gate.rest = everyProgram
	type decision struct{ tunnel, listed bool }
	decisions := map[int]decision{}
	self := os.Getpid()
	own := ""
	if executable, err := os.Executable(); err == nil {
		own = filepath.Base(executable)
	}
	coreServerMu.Lock()
	before := keptOpened
	coreServerMu.Unlock()
	var entries []dispatcher.RecentConnection
	var keeps []xnet.TCPConnection
	for _, connection := range connections {
		process, ok := processes[connection.PID]
		if !ok || connection.PID == self || !outsideTunnel(connection, tunnel, routed != nil) {
			continue
		}
		if _, known := before[connection]; known {
			continue
		}
		decided, seen := decisions[connection.PID]
		if !seen {
			decided.tunnel, decided.listed = gate.decides(process)
			if !decided.listed && strings.EqualFold(filepath.Base(process.Path), own) {
				decided.tunnel = false
			}
			decisions[connection.PID] = decided
		}
		if !decided.tunnel || routed != nil && !routed(connection.Remote.Addr().Unmap()) {
			continue
		}
		before := "reset"
		if xnet.ResetTCPConnection(connection) != nil {
			before = "kept"
			keeps = append(keeps, connection)
			kept++
		} else {
			reset++
		}
		if decided.listed {
			entries = append(entries, dispatcher.RecentConnection{Network: "tcp", Host: connection.Remote.Addr().Unmap().String(),
				Port: connection.Remote.Port(), Owner: "found", PID: process.PID, Name: process.Name, Path: process.Path, Before: before})
		}
	}
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == server {
		if keptOpened == nil {
			keptOpened = map[xnet.TCPConnection]struct{}{}
		}
		for _, connection := range keeps {
			keptOpened[connection] = struct{}{}
		}
		if recent, ok := server.GetFeature(routing.DispatcherType()).(*dispatcher.DefaultDispatcher); ok {
			recent.NoteOpenedBefore(entries)
		}
	}
	return reset, kept
}
