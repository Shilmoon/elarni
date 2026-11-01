package share

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

// Configs written by native/elarni-domain/src/router_fixtures.rs. Their dns.hosts
// answer every lookup the router makes, so these tests never leave this host.
// Embedded because check-android runs the test binary on a device, away from testdata/.
//
//go:embed testdata/compiled_routing.json
var compiledRoutingJSON []byte

func compiledRoutingFixture(t *testing.T, name string) map[string]any {
	t.Helper()
	var fixtures map[string]map[string]any
	if err := json.Unmarshal(compiledRoutingJSON, &fixtures); err != nil {
		t.Fatal(err)
	}
	config := fixtures[name]
	if config == nil {
		t.Fatalf("missing fixture %s", name)
	}
	// Routes are picked and dispatched without opening the app listeners.
	config["inbounds"] = []any{}
	return config
}

func pickCompiledRoute(t *testing.T, router routing.Router, inbound string, target xnet.Address) string {
	t.Helper()
	route, err := router.PickRoute(&routingsession.Context{
		Inbound:  &session.Inbound{Tag: inbound},
		Outbound: &session.Outbound{Target: xnet.TCPDestination(target, 443)},
		Content:  &session.Content{},
	})
	if err != nil {
		t.Fatalf("%s %s: %v", inbound, target, err)
	}
	return route.GetOutboundTag()
}

func TestCompiledRoutingMatchesIPRulesForHostnames(t *testing.T) {
	instance, stop := startTrafficCore(t, compiledRoutingFixture(t, "outbound"))
	defer stop()
	router := instance.GetFeature(routing.RouterType()).(routing.Router)
	for _, fixture := range []struct {
		target xnet.Address
		want   string
	}{
		{xnet.DomainAddress("blocked.test"), "elarni-block"},
		{xnet.ParseAddress("198.51.100.20"), "elarni-direct"},
		{xnet.DomainAddress("direct-range.test"), "elarni-direct"},
		{xnet.DomainAddress("outside.test"), "elarni-proxy"},
		{xnet.ParseAddress("203.0.113.10"), "elarni-proxy"},
	} {
		if got := pickCompiledRoute(t, router, "elarni-socks", fixture.target); got != fixture.want {
			t.Errorf("%s: got %s, want %s", fixture.target, got, fixture.want)
		}
	}
}

func TestCompiledProviderReentryMatchesIPRulesForHostnames(t *testing.T) {
	instance, stop := startTrafficCore(t, compiledRoutingFixture(t, "profile"))
	defer stop()
	router := instance.GetFeature(routing.RouterType()).(routing.Router)
	for _, fixture := range []struct {
		inbound string
		target  xnet.Address
		want    string
	}{
		{"elarni-socks", xnet.DomainAddress("blocked.test"), "elarni-block"},
		{"elarni-socks", xnet.DomainAddress("loopback-range.test"), "elarni-proxy"},
		{"elarni-provider", xnet.DomainAddress("loopback-range.test"), "direct"},
		{"elarni-provider", xnet.ParseAddress("192.0.2.10"), "proxy"},
	} {
		if got := pickCompiledRoute(t, router, fixture.inbound, fixture.target); got != fixture.want {
			t.Errorf("%s %s: got %s, want %s", fixture.inbound, fixture.target, got, fixture.want)
		}
	}
	// App proxy traffic passes the real loopback into the provider policy, whose
	// IP rule sends the hostname direct to the echo listener; the provider's
	// fallback node refuses connections.
	for _, network := range []string{"tcp", "udp"} {
		trafficRoundTripFromInbound(t, instance, network, "127.0.0.1", "elarni-socks", "loopback-range.test")
	}
}

// Per-app routing sends a listed app's TUN traffic through a loopback back into
// the profile's rules (compiler.rs apply_per_app_routing). A provider rule that
// matches the sniffed protocol must still match on that second pass.
func TestPerAppReentryKeepsSniffedProtocol(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(conn, conn); conn.Close() }()
		}
	}()
	port := trafficPort(t)
	var config map[string]any
	if err := json.Unmarshal([]byte(fmt.Sprintf(`{
		"inbounds": [{"tag": "elarni-tun", "listen": "127.0.0.1", "port": %d, "protocol": "dokodemo-door",
			"settings": {"address": "127.0.0.1", "port": %d, "network": "tcp"},
			"sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}}],
		"outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"},
			{"tag": "elarni-apps-0", "protocol": "loopback", "settings": {"inboundTag": "elarni-apps-0"}}],
		"routing": {"rules": [
			{"type": "field", "inboundTag": ["elarni-tun"], "network": "tcp,udp", "outboundTag": "elarni-apps-0"},
			{"type": "field", "inboundTag": ["elarni-apps-0"], "protocol": ["http"], "outboundTag": "block"},
			{"type": "field", "inboundTag": ["elarni-apps-0"], "network": "tcp,udp", "outboundTag": "direct"}]}
	}`, port, echo.Addr().(*net.TCPAddr).Port)), &config); err != nil {
		t.Fatal(err)
	}
	_, stop := startTrafficCore(t, config)
	defer stop()
	// Traffic that no rule blocks still re-enters and reaches the echo server.
	control, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	payload := []byte("ping\n")
	control.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := control.Write(payload); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(control, make([]byte, len(payload))); err != nil {
		t.Fatalf("re-entered traffic did not reach the echo server: %v", err)
	}
	conn, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	request := []byte("GET / HTTP/1.1\r\nHost: app.test\r\n\r\n")
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(request); err != nil {
		t.Fatal(err)
	}
	if n, err := io.ReadFull(conn, make([]byte, len(request))); err == nil {
		t.Fatalf("the http rule did not block re-entered traffic; %d bytes echoed", n)
	}
}

// In proxy mode with automatic IP preference the direct outbound dials names
// AsIs. The fixture's pinned name exists only in its DnsHosts, and the proxy
// fallback refuses connections, so only a direct dial to the pin echoes.
func TestCompiledDirectRouteDialsDnsHostsPin(t *testing.T) {
	instance, stop := startTrafficCore(t, compiledRoutingFixture(t, "automatic-ip"))
	defer stop()
	for _, network := range []string{"tcp", "udp"} {
		trafficRoundTripFromInbound(t, instance, network, "127.0.0.1", "elarni-socks", "pinned-direct.test")
	}
}
