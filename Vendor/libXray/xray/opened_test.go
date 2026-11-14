//go:build (darwin && !ios) || windows || (linux && !android)

package xray

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

// An opened-before test starts copies of the test binary, other programs, which hold a
// connection here: they print "ready <port>", then each byte they read, then why reading failed.
func TestHelperHoldsAConnection(t *testing.T) {
	address := os.Getenv("ELARNI_HOLD_CONNECTION")
	if address == "" {
		return
	}
	connection, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		fmt.Println("dial", err)
		return
	}
	fmt.Println("ready", connection.LocalAddr().(*net.TCPAddr).Port)
	_ = connection.SetReadDeadline(time.Now().Add(30 * time.Second))
	for buf := make([]byte, 1); ; {
		if _, err := connection.Read(buf); err != nil {
			fmt.Println("closed", err)
			return
		}
		fmt.Println("got", string(buf))
	}
}

type heldConnection struct {
	command *exec.Cmd
	lines   *bufio.Reader
	server  net.Conn // this test's end
	path    string
}

func holdConnection(t *testing.T, binary []byte, path string, listener net.Listener, accepted <-chan net.Conn) *heldConnection {
	t.Helper()
	if err := os.WriteFile(path, binary, 0o700); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(path, "-test.run=^TestHelperHoldsAConnection$")
	command.Env = append(os.Environ(), "ELARNI_HOLD_CONNECTION="+listener.Addr().String())
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
	held := &heldConnection{command: command, lines: bufio.NewReader(output), path: path}
	line, err := held.lines.ReadString('\n')
	if err != nil || !strings.HasPrefix(line, "ready ") {
		t.Fatalf("%s: %q %v", filepath.Base(path), line, err)
	}
	select {
	case held.server = <-accepted:
	case <-time.After(5 * time.Second):
		t.Fatal("no connection")
	}
	t.Cleanup(func() { held.server.Close() })
	return held
}

// alive sends a byte through the connection and waits for the program to read it.
func (h *heldConnection) alive(t *testing.T) {
	t.Helper()
	if _, err := h.server.Write([]byte("k")); err != nil {
		t.Fatalf("%s: write: %v", filepath.Base(h.path), err)
	}
	if line, err := h.lines.ReadString('\n'); err != nil || line != "got k\n" {
		t.Fatalf("%s's connection does not work: %q %v", filepath.Base(h.path), line, err)
	}
}

func resolvedTempDir(t *testing.T) string {
	dir := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(dir); err == nil {
		dir = resolved
	}
	return dir
}

// A listed app that was running before the tunnel started keeps connections that skip per-app
// routing. The core resets them where the system lets it, so the app reconnects through the
// tunnel, and the connections view lists them either way. A listed app whose target is Direct
// keeps its connections.
func TestMoveOpenedConnectionsResetsTheListedAppsConnections(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	dir := resolvedTempDir(t)
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			accepted <- connection
		}
	}()
	listed := holdConnection(t, binary, filepath.Join(dir, "listed"+suffix), listener, accepted)
	direct := holdConnection(t, binary, filepath.Join(dir, "direct"+suffix), listener, accepted)

	// The connections here run over loopback, which a real tunnel leaves alone.
	previous := outsideTunnel
	outsideTunnel = func(connection xnet.TCPConnection, _ []netip.Prefix, _ bool) bool {
		return connection.Remote == netip.MustParseAddrPort(listener.Addr().String())
	}
	t.Cleanup(func() { outsideTunnel = previous })

	config := map[string]any{
		"inbounds": []any{map[string]any{"tag": "elarni-tun", "listen": "127.0.0.1", "port": 0, "protocol": "dokodemo-door",
			"settings": map[string]any{"network": "tcp", "address": "127.0.0.1", "port": 9}}},
		"outbounds": []any{
			map[string]any{"tag": "elarni-direct", "protocol": "freedom"},
			map[string]any{"tag": "elarni-apps-0", "protocol": "loopback", "settings": map[string]any{"inboundTag": "elarni-apps-0"}},
		},
		"routing": map[string]any{"rules": []any{
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "process": []string{listed.path},
				"outboundTag": "elarni-apps-0", "ruleTag": "elarni-per-app-listed-0"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "process": []string{direct.path},
				"outboundTag": "elarni-direct", "ruleTag": "elarni-per-app-listed-1"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "outboundTag": "elarni-direct", "ruleTag": "elarni-per-app-other"},
		}},
	}
	raw, _ := json.Marshal(config)
	if err := RunXrayFromJSON(string(raw)); err != nil {
		t.Fatal(err)
	}
	defer StopXray()

	reset, kept := MoveOpenedConnections(nil, nil)
	result, err := ReadConnections(0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if reset+kept != 1 || len(result.Connections) != 1 {
		t.Fatalf("reset %d, kept %d, entries %+v", reset, kept, result.Connections)
	}
	entry := result.Connections[0]
	samePath := entry.Path == filepath.ToSlash(listed.path) ||
		runtime.GOOS == "windows" && strings.EqualFold(filepath.FromSlash(entry.Path), listed.path)
	if entry.Owner != "found" || entry.PID != listed.command.Process.Pid || !samePath || entry.Network != "tcp" ||
		entry.Host != "127.0.0.1" || strconv.Itoa(int(entry.Port)) != strings.Split(listener.Addr().String(), ":")[1] {
		t.Fatalf("entry %+v, want %s's connection", entry, listed.path)
	}
	switch {
	case entry.Before == "reset" && reset == 1:
		if runtime.GOOS == "darwin" {
			t.Fatal("macOS reset a connection")
		}
		if line, err := listed.lines.ReadString('\n'); err != nil || !strings.HasPrefix(line, "closed ") {
			t.Fatalf("the reset connection still works: %q %v", line, err)
		}
	case entry.Before == "kept" && kept == 1:
		listed.alive(t)
	default:
		t.Fatalf("entry %+v, reset %d, kept %d", entry, reset, kept)
	}
	t.Logf("the listed app's connection was %s", entry.Before)
	direct.alive(t)
}

func TestPerAppRulesKeepTheRoutersOrderAndTargets(t *testing.T) {
	config := `{"outbounds":[{"tag":"elarni-direct","protocol":"freedom"},{"tag":"elarni-block","protocol":"blackhole"},
		{"tag":"elarni-apps-0","protocol":"loopback"},{"tag":"elarni-app-0","protocol":"vless"}],
		"routing":{"rules":[{"ruleTag":"elarni-per-app-dns","port":53,"outboundTag":"elarni-apps-0"},
		{"ruleTag":"elarni-per-app-listed-0","process":["/opt/a"],"outboundTag":"elarni-apps-0"},
		{"ruleTag":"elarni-per-app-listed-1","process":["/opt/direct"],"outboundTag":"elarni-direct"},
		{"ruleTag":"elarni-per-app-listed-2","process":["/opt/blocked"],"outboundTag":"elarni-block"},
		{"ruleTag":"elarni-per-app-listed-3","process":["/opt/server"],"outboundTag":"elarni-app-0"},
		{"ruleTag":"elarni-per-app-listed-4","process":["children:/opt/a"],"outboundTag":"elarni-apps-0"},
		{"ruleTag":"elarni-per-app-other","outboundTag":"elarni-direct"},
		{"process":["/opt/user"],"outboundTag":"elarni-block"}]}}`
	var got []string
	rules, rest := perAppGate(config)
	for _, rule := range rules {
		got = append(got, fmt.Sprintf("%s=%t", strings.Join(rule.processes, ","), rule.tunnel))
	}
	if want := "/opt/a=true /opt/direct=false /opt/blocked=true /opt/server=true children:/opt/a=true"; strings.Join(got, " ") != want {
		t.Fatalf("rules %q, want %q", got, want)
	}
	if rest {
		t.Fatal("the other programs go direct, and the gate sends them into the tunnel")
	}
	// The other programs go on to the normal routing, or there is no per-app routing at all.
	for _, config := range []string{
		`{"outbounds":[{"tag":"elarni-direct","protocol":"freedom"},{"tag":"elarni-apps-0","protocol":"loopback"}],
			"routing":{"rules":[{"ruleTag":"elarni-per-app-listed-0","process":["/opt/a"],"outboundTag":"elarni-direct"},
			{"ruleTag":"elarni-per-app-other","outboundTag":"elarni-apps-0"}]}}`,
		`{"outbounds":[{"tag":"elarni-direct","protocol":"freedom"}],"routing":{"rules":[{"outboundTag":"elarni-direct"}]}}`,
	} {
		if _, rest := perAppGate(config); !rest {
			t.Fatalf("the tunnel does not take the other programs of %s", config)
		}
	}
	if rules, _ := perAppGate("{"); rules != nil {
		t.Fatal("rules from invalid JSON")
	}
}

// Windows keeps a connection on the network it was opened on: one opened before the tunnel, or
// between two tunnels, would run outside it for as long as it lives. Where the system now routes
// its destination into the tunnel, the core resets it for every program the tunnel takes, not
// only for listed ones, and lists none of those.
func TestMoveOpenedConnectionsResetsWhatTheTunnelNowTakes(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			accepted <- connection
		}
	}()
	target := netip.MustParseAddrPort(listener.Addr().String())
	previous := outsideTunnel
	outsideTunnel = func(connection xnet.TCPConnection, _ []netip.Prefix, _ bool) bool { return connection.Remote == target }
	t.Cleanup(func() { outsideTunnel = previous })
	routed := func(address netip.Addr) bool { return address == target.Addr() }
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	// moved tells whether the pass reset the program's connection; one the system does not let
	// the core reset still works.
	moved := func(t *testing.T, held *heldConnection, reset, kept int) {
		t.Helper()
		switch {
		case reset == 1 && kept == 0:
			if line, err := held.lines.ReadString('\n'); err != nil || !strings.HasPrefix(line, "closed ") {
				t.Fatalf("the reset connection still works: %q %v", line, err)
			}
		case reset == 0 && kept == 1:
			held.alive(t)
		default:
			t.Fatalf("reset %d, kept %d, want the one connection", reset, kept)
		}
		if again, still := MoveOpenedConnections(nil, routed); again != 0 || still != 0 {
			t.Fatalf("a second pass reset %d and kept %d", again, still)
		}
		if result, err := ReadConnections(0, 0); err != nil || len(result.Connections) != 0 {
			t.Fatalf("listed %+v %v, want none: no listed app owns it", result, err)
		}
	}
	for _, c := range []struct {
		name  string
		rules func(direct string) []any
		moves bool
	}{
		{"without per-app routing", func(string) []any { return nil }, true},
		{"when only listed apps use the tunnel", func(string) []any {
			return []any{map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "outboundTag": "elarni-direct", "ruleTag": "elarni-per-app-other"}}
		}, false},
		{"when listed apps skip the tunnel", func(direct string) []any {
			return []any{
				map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "process": []string{direct},
					"outboundTag": "elarni-direct", "ruleTag": "elarni-per-app-listed-0"},
				map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "outboundTag": "elarni-apps-0", "ruleTag": "elarni-per-app-other"},
			}
		}, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := resolvedTempDir(t)
			if err := os.Mkdir(filepath.Join(dir, "own"), 0o700); err != nil {
				t.Fatal(err)
			}
			app := holdConnection(t, binary, filepath.Join(dir, "app"+suffix), listener, accepted)
			direct := holdConnection(t, binary, filepath.Join(dir, "direct"+suffix), listener, accepted)
			// Another process of this program, as the app's own core is to its elevated helper.
			own := holdConnection(t, binary, filepath.Join(dir, "own", filepath.Base(self)), listener, accepted)
			config := map[string]any{
				"inbounds": []any{map[string]any{"tag": "elarni-tun", "listen": "127.0.0.1", "port": 0, "protocol": "dokodemo-door",
					"settings": map[string]any{"network": "tcp", "address": "127.0.0.1", "port": 9}}},
				"outbounds": []any{
					map[string]any{"tag": "elarni-direct", "protocol": "freedom"},
					map[string]any{"tag": "elarni-apps-0", "protocol": "loopback", "settings": map[string]any{"inboundTag": "elarni-apps-0"}},
				},
				"routing": map[string]any{"rules": c.rules(direct.path)},
			}
			raw, _ := json.Marshal(config)
			if err := RunXrayFromJSON(string(raw)); err != nil {
				t.Fatal(err)
			}
			defer StopXray()
			if reset, kept := MoveOpenedConnections(nil, func(netip.Addr) bool { return false }); reset != 0 || kept != 0 {
				t.Fatalf("reset %d and kept %d to a destination the tunnel does not take", reset, kept)
			}
			reset, kept := MoveOpenedConnections(nil, routed)
			if c.name == "without per-app routing" {
				// direct is one more program the tunnel takes.
				if reset+kept != 2 {
					t.Fatalf("reset %d, kept %d, want both programs' connections", reset, kept)
				}
				reset, kept = reset/2, kept/2
			} else {
				direct.alive(t)
			}
			if c.moves {
				moved(t, app, reset, kept)
			} else if reset != 0 || kept != 0 {
				t.Fatalf("reset %d and kept %d of a program that skips the tunnel", reset, kept)
			} else {
				app.alive(t)
			}
			own.alive(t)
		})
	}
}

// A program the router sends direct by an earlier rule stays out of the tunnel, even when a later
// rule, such as its starter's "children:" rule, would take it.
func TestPerAppTunnelFollowsTheFirstMatchingRule(t *testing.T) {
	gate := newPerAppTunnel([]perAppRule{{processes: []string{"helper"}}, {processes: []string{"helper", "tool"}, tunnel: true}})
	for name, want := range map[string]bool{"helper": false, "tool": true, "other": false} {
		if got := gate.takes(xnet.Process{Name: name}); got != want {
			t.Errorf("%s: tunnel %t, want %t", name, got, want)
		}
	}
}

func TestOutsideTunnelKeepsLocalNetworks(t *testing.T) {
	tunnel := []netip.Prefix{netip.MustParsePrefix("198.51.100.252/30"), netip.MustParsePrefix("fd76:6f75:7465::/126")}
	// routed: where the system's routes say which remote addresses the tunnel takes, a private
	// one is not left out here.
	for _, c := range []struct {
		local, remote string
		want, routed  bool
	}{
		{"192.168.1.20:50000", "203.0.114.9:443", true, true},
		{"[2001:db8:5::20]:50000", "[2606:4700::1111]:443", true, true},
		{"[::ffff:192.168.1.20]:50000", "[::ffff:203.0.114.9]:443", true, true},
		{"198.51.100.254:50000", "203.0.114.9:443", false, false},
		{"[fd76:6f75:7465::2]:50000", "[2606:4700::1111]:443", false, false},
		{"192.168.1.20:50000", "192.168.1.1:80", false, true},
		{"10.0.0.2:50000", "10.0.0.1:443", false, true},
		{"100.101.1.2:50000", "100.64.0.1:443", false, true},
		{"[fe80::1]:50000", "[fe80::2]:443", false, true},
		{"127.0.0.1:50000", "127.0.0.1:443", false, false},
		{"[::1]:50000", "[::1]:443", false, false},
		{"192.168.1.20:50000", "127.0.0.1:443", false, false},
	} {
		connection := xnet.TCPConnection{Local: netip.MustParseAddrPort(c.local), Remote: netip.MustParseAddrPort(c.remote)}
		if got := outsideTunnel(connection, tunnel, false); got != c.want {
			t.Errorf("%s -> %s: %v, want %v", c.local, c.remote, got, c.want)
		}
		if got := outsideTunnel(connection, tunnel, true); got != c.routed {
			t.Errorf("%s -> %s, the routes decide: %v, want %v", c.local, c.remote, got, c.routed)
		}
	}
}
