package share

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestWindowsElevationOwnsLocalResources(t *testing.T) {
	fixture := func() map[string]any {
		return map[string]any{
			"log": map[string]any{"access": "untrusted-output"},
			"inbounds": []any{map[string]any{"protocol": "tun", "settings": map[string]any{"name": "untrusted", "gateway": []string{"1.2.3.4/8"}}},
				map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": float64(10890)}},
			"outbounds": []any{map[string]any{"protocol": "vless", "tag": "proxy", "settings": map[string]any{}}},
		}
	}
	encode := func(value any) []byte {
		result, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	config, err := WindowsTunnelConfig(encode(fixture()), "elarni-fixture")
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if json.Unmarshal(config, &result) != nil {
		t.Fatal("bad config")
	}
	tun := result["inbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)
	if tun["name"] != "elarni-fixture" || len(tun["autoSystemRoutingTable"].([]any)) != 4 ||
		result["log"].(map[string]any)["access"] != nil {
		t.Fatal("caller controlled elevated resources")
	}
	// At 1500 the TUN path cost about 50% more core CPU per Mbps, which caps throughput on a busy 2-vCPU machine.
	if tun["mtu"] != float64(9000) {
		t.Fatalf("Windows TUN MTU %v, want 9000", tun["mtu"])
	}
	// CGNAT is Tailscale's (its firewall drops 100.64/10 from other interfaces) and private
	// ranges are LANs and Docker networks; documentation ranges appear on no real network.
	for _, value := range append(tun["gateway"].([]any), tun["dns"].([]any)...) {
		address := strings.Split(value.(string), "/")[0]
		ip := net.ParseIP(address)
		_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
		_, testNet, _ := net.ParseCIDR("198.51.100.0/24")
		if ip == nil || cgnat.Contains(ip) || (ip.To4() != nil && (ip.IsPrivate() || !testNet.Contains(ip))) {
			t.Fatalf("TUN address %s can collide with a real network", address)
		}
	}
	for _, override := range []string{"tls", "fakedns"} {
		t.Run("preserve "+override+" sniffing", func(t *testing.T) {
			input := fixture()
			sniffing := map[string]any{"enabled": true, "destOverride": []any{override}, "routeOnly": override != "fakedns"}
			input["inbounds"].([]any)[0].(map[string]any)["sniffing"] = sniffing
			owned, err := WindowsTunnelConfig(encode(input), "elarni-fixture")
			var output map[string]any
			if err != nil || json.Unmarshal(owned, &output) != nil {
				t.Fatal("invalid owned config", err)
			}
			if !reflect.DeepEqual(output["inbounds"].([]any)[0].(map[string]any)["sniffing"], sniffing) {
				t.Fatal("TUN lost domain routing/FakeDNS sniffing")
			}
		})
	}
	authenticated := fixture()
	socks := authenticated["inbounds"].([]any)[1].(map[string]any)
	socks["listen"] = "0.0.0.0"
	socks["settings"] = map[string]any{"auth": "password", "accounts": []any{map[string]any{"user": "fixture", "pass": "fixture-secret"}}}
	secured, err := WindowsTunnelConfig(encode(authenticated), "elarni-fixture")
	if err != nil {
		t.Fatal(err)
	}
	var securedConfig map[string]any
	if json.Unmarshal(secured, &securedConfig) != nil {
		t.Fatal("bad authenticated config")
	}
	listener := securedConfig["inbounds"].([]any)[1].(map[string]any)
	if listener["listen"] != "0.0.0.0" || listener["settings"].(map[string]any)["auth"] != "password" {
		t.Fatal("elevation discarded listener authentication")
	}
	for name, mutate := range map[string]func(map[string]any){
		"file logging": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"realitySettings": map[string]any{"masterKeyLog": "private-path"}}
		},
		"certificate file": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"tlsSettings": map[string]any{"certificates": []any{map[string]any{"certificateFile": "private-path"}}}}
		},
		"system hosts":             func(c map[string]any) { c["dns"] = map[string]any{"useSystemHosts": true} },
		"case-folded system hosts": func(c map[string]any) { c["dns"] = map[string]any{"UseSystemHosts": true} },
		"case-folded interface": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"sockopt": map[string]any{"Interface": "eth0"}}
		},
		// Raw setsockopt from a root/elevated helper can bind any device (SO_BINDTODEVICE).
		"custom socket options": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"sockopt": map[string]any{"CustomSockopt": []any{
				map[string]any{"system": "linux", "type": "str", "level": "1", "opt": "25", "value": "eth0"}}}}
		},
		// encoding/json also folds U+017F (long s) to s and U+212A (Kelvin) to k.
		"unicode-folded custom socket options": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"sockopt": map[string]any{"cuſtomSockopt": []any{
				map[string]any{"system": "windows", "type": "int", "level": "65535", "opt": "4", "value": "1"}}}}
		},
		"unicode-folded system hosts": func(c map[string]any) { c["dns"] = map[string]any{"uſeSystemHosts": true} },
		// Sorted after "rules" on re-encoding, it would replace the owned DNS rule.
		"unicode-folded rule list": func(c map[string]any) {
			c["routing"] = map[string]any{"ruleſ": []any{map[string]any{"outboundTag": "proxy"}}}
		},
		"case-folded duplicate key": func(c map[string]any) {
			c["dns"] = map[string]any{"servers": []any{"1.1.1.1"}, "Servers": []any{"localhost"}}
		},
		"routing webhook to a socket": func(c map[string]any) {
			c["routing"] = map[string]any{"rules": []any{map[string]any{"outboundTag": "direct", "webhook": map[string]any{"url": "/var/run/docker.sock:/v1.43/volumes/prune"}}}}
		},
		"routing webhook to a URL": func(c map[string]any) {
			c["routing"] = map[string]any{"rules": []any{map[string]any{"outboundTag": "direct", "Webhook": map[string]any{"url": "http://192.168.1.1/x"}}}}
		},
		"unix transport": func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["streamSettings"] = map[string]any{"network": "unix"}
		},
		"external geodata": func(c map[string]any) {
			c["routing"] = map[string]any{"rules": []any{map[string]any{"domain": []string{"ext:private.dat:any"}}}}
		},
		"geodata downloader":    func(c map[string]any) { c["geodata"] = map[string]any{"assets": []any{}} },
		"non-loopback listener": func(c map[string]any) { c["inbounds"].([]any)[1].(map[string]any)["listen"] = "0.0.0.0" },
		"inbound server":        func(c map[string]any) { c["inbounds"].([]any)[1].(map[string]any)["protocol"] = "vless" },
	} {
		t.Run(name, func(t *testing.T) {
			c := fixture()
			mutate(c)
			if _, err := WindowsTunnelConfig(encode(c), "elarni-fixture"); err == nil {
				t.Fatal("privileged request accepted")
			}
		})
	}
	t.Run("folded kernel TUN override", func(t *testing.T) {
		c := fixture()
		c["outbounds"] = []any{map[string]any{"protocol": "wireguard", "tag": "proxy", "settings": map[string]any{"nokerneltun": false}}}
		owned, err := WindowsTunnelConfig(encode(c), "elarni-fixture")
		var output map[string]any
		if err != nil || json.Unmarshal(owned, &output) != nil {
			t.Fatal("invalid owned config", err)
		}
		settings := output["outbounds"].([]any)[0].(map[string]any)["settings"]
		if !reflect.DeepEqual(settings, map[string]any{"noKernelTun": true}) {
			t.Fatalf("kernel TUN not forced off: %v", settings)
		}
	})
}

// Xray reads a named geodata file for each ext prefix, negated IP rules and DNS host keys
// included; the elevated core may only use the bundled files.
func TestWindowsElevationRefusesEveryExternalGeodataForm(t *testing.T) {
	config := func(dns, routing map[string]any) []byte {
		result, err := json.Marshal(map[string]any{
			"inbounds": []any{map[string]any{"protocol": "tun", "settings": map[string]any{}},
				map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": float64(10890)}},
			"outbounds": []any{map[string]any{"protocol": "freedom", "tag": "direct"}},
			"dns":       dns, "routing": routing,
		})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	rule := func(field, value string) map[string]any {
		return map[string]any{"rules": []any{map[string]any{field: []any{value}, "outboundTag": "direct"}}}
	}
	for name, input := range map[string][]byte{
		"ext-site":       config(nil, rule("domain", "ext-site:private.dat:any")),
		"ext-domain":     config(nil, rule("domain", "ext-domain:private.dat:any")),
		"negated ext":    config(nil, rule("ip", "!ext:private.dat:any")),
		"negated ip":     config(nil, rule("ip", "!!ext-ip:private.dat:any")),
		"hosts key":      config(map[string]any{"hosts": map[string]any{"ext:private.dat:any": "192.0.2.1"}}, nil),
		"hosts ext-site": config(map[string]any{"hosts": map[string]any{"ext-site:private.dat:any": "192.0.2.1"}}, nil),
	} {
		if _, err := WindowsTunnelConfig(input, "elarni-fixture"); err == nil {
			t.Errorf("%s: external geodata accepted", name)
		}
	}
	for name, input := range map[string][]byte{
		"bundled site":    config(nil, rule("domain", "ext-site:geosite.dat:cn")),
		"bundled negated": config(nil, rule("ip", "!ext-ip:geoip.dat:cn")),
		// Xray reads ext: in an IP rule from the named geoip file; geoip: is its short form.
		"bundled ext ip":      config(nil, rule("ip", "ext:geoip.dat:cn")),
		"bundled ext negated": config(nil, rule("ip", "!ext:geoip.dat:cn")),
		"bundled hosts":       config(map[string]any{"hosts": map[string]any{"ext:geosite.dat:cn": "192.0.2.1"}}, nil),
	} {
		if _, err := WindowsTunnelConfig(input, "elarni-fixture"); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// Xray's DNS answers only A and AAAA itself. SRV, MX, TXT and other lookups made
// through the TUN must still reach a resolver instead of getting an empty answer.
func TestWindowsTunnelDNSForwardsOtherQueryTypes(t *testing.T) {
	upstream, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer upstream.Close()
	var mu sync.Mutex
	asked := map[dnsmessage.Type]int{}
	go func() {
		packet := make([]byte, 2048)
		for {
			n, peer, err := upstream.ReadFrom(packet)
			if err != nil {
				return
			}
			var query dnsmessage.Message
			if query.Unpack(packet[:n]) != nil || len(query.Questions) != 1 {
				continue
			}
			question := query.Questions[0]
			mu.Lock()
			asked[question.Type]++
			mu.Unlock()
			header := dnsmessage.ResourceHeader{Name: question.Name, Type: question.Type, Class: dnsmessage.ClassINET, TTL: 60}
			reply := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, RecursionAvailable: true}, Questions: query.Questions}
			switch question.Type {
			case dnsmessage.TypeA:
				reply.Answers = []dnsmessage.Resource{{Header: header, Body: &dnsmessage.AResource{A: [4]byte{192, 0, 2, 7}}}}
			case dnsmessage.TypeTXT:
				reply.Answers = []dnsmessage.Resource{{Header: header, Body: &dnsmessage.TXTResource{TXT: []string{"upstream"}}}}
			case dnsmessage.TypeSRV:
				reply.Answers = []dnsmessage.Resource{{Header: header, Body: &dnsmessage.SRVResource{Port: 5222, Target: dnsmessage.MustNewName("xmpp.example.")}}}
			case dnsmessage.TypeMX:
				reply.Answers = []dnsmessage.Resource{{Header: header, Body: &dnsmessage.MXResource{Pref: 10, MX: dnsmessage.MustNewName("mail.example.")}}}
			}
			if out, err := reply.Pack(); err == nil {
				upstream.WriteTo(out, peer)
			}
		}
	}()
	socksPort, tunPort := trafficPort(t), trafficPort(t)
	input, err := json.Marshal(map[string]any{
		"dns": map[string]any{"tag": "elarni-dns-client", "servers": []any{
			"fakedns", map[string]any{"address": "127.0.0.1", "port": upstream.LocalAddr().(*net.UDPAddr).Port}}},
		"inbounds":  []any{map[string]any{"protocol": "tun"}, map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": socksPort}},
		"outbounds": []any{map[string]any{"protocol": "freedom", "tag": "direct"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	owned, err := WindowsTunnelConfig(input, "elarni-fixture")
	if err != nil {
		t.Fatal(err)
	}
	var profile map[string]any
	if err := json.Unmarshal(owned, &profile); err != nil {
		t.Fatal(err)
	}
	// Creating the adapter needs elevation; a listener with its tag receives what
	// Windows sends to the adapter's DNS address.
	profile["inbounds"].([]any)[0] = map[string]any{"tag": "elarni-tun", "protocol": "dokodemo-door", "listen": "127.0.0.1", "port": tunPort,
		"settings": map[string]any{"address": TunDNS4, "port": 53, "network": "udp"}}
	delete(profile, "fakeDns")
	profile["dns"].(map[string]any)["servers"] = profile["dns"].(map[string]any)["servers"].([]any)[1:]
	_, stop := startTrafficCore(t, profile)
	defer stop()
	conn, err := net.Dial("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(tunPort)))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	lookup := func(qType dnsmessage.Type) dnsmessage.Message {
		t.Helper()
		query := dnsmessage.Message{Header: dnsmessage.Header{ID: uint16(qType), RecursionDesired: true},
			Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("_xmpp._tcp.example."), Type: qType, Class: dnsmessage.ClassINET}}}
		packet, err := query.Pack()
		if err != nil {
			t.Fatal(err)
		}
		for range 3 {
			conn.Write(packet)
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			reply := make([]byte, 2048)
			n, err := conn.Read(reply)
			if err != nil {
				continue
			}
			var answer dnsmessage.Message
			if answer.Unpack(reply[:n]) == nil && answer.ID == query.ID {
				return answer
			}
		}
		t.Fatalf("no answer to the %v query", qType)
		return dnsmessage.Message{}
	}
	for _, qType := range []dnsmessage.Type{dnsmessage.TypeTXT, dnsmessage.TypeSRV, dnsmessage.TypeMX, dnsmessage.TypeA} {
		if answer := lookup(qType); answer.RCode != dnsmessage.RCodeSuccess || len(answer.Answers) != 1 {
			t.Errorf("%v: rcode %v with %d answers, want the resolver's answer", qType, answer.RCode, len(answer.Answers))
		}
	}
	// HTTPS records would hand browsers addresses that bypass FakeDNS and A/AAAA policy.
	if answer := lookup(dnsmessage.Type(65)); len(answer.Answers) != 0 {
		t.Errorf("HTTPS record answered with %d records, want none", len(answer.Answers))
	}
	mu.Lock()
	defer mu.Unlock()
	if asked[dnsmessage.Type(65)] != 0 {
		t.Error("HTTPS record query reached the resolver")
	}
}

// Windows retries a truncated answer over TCP; forwarding that retry over UDP
// truncates it again, so large answers never resolve.
func TestWindowsTunnelDNSKeepsTCPQueriesOnTCP(t *testing.T) {
	// A system-chosen UDP port can have its TCP twin taken; trafficPort finds one free for both.
	port := trafficPort(t)
	udp, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	reply := func(packet []byte, truncated bool) []byte {
		var query dnsmessage.Message
		if query.Unpack(packet) != nil || len(query.Questions) != 1 {
			return nil
		}
		answer := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, Truncated: truncated}, Questions: query.Questions}
		for i := 0; !truncated && i < 20; i++ {
			answer.Answers = append(answer.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeTXT, Class: dnsmessage.ClassINET, TTL: 60},
				Body: &dnsmessage.TXTResource{TXT: []string{strings.Repeat("x", 200)}}})
		}
		out, _ := answer.Pack()
		return out
	}
	go func() {
		packet := make([]byte, 65535)
		for {
			n, peer, err := udp.ReadFrom(packet)
			if err != nil {
				return
			}
			udp.WriteTo(reply(packet[:n], true), peer)
		}
	}()
	go func() {
		for {
			conn, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var size uint16
				if binary.Read(conn, binary.BigEndian, &size) != nil {
					return
				}
				packet := make([]byte, size)
				if _, err := io.ReadFull(conn, packet); err != nil {
					return
				}
				out := reply(packet, false)
				binary.Write(conn, binary.BigEndian, uint16(len(out)))
				conn.Write(out)
			}()
		}
	}()
	socksPort, tunPort := trafficPort(t), trafficPort(t)
	input, err := json.Marshal(map[string]any{
		"dns":       map[string]any{"tag": "elarni-dns-client", "servers": []any{map[string]any{"address": "127.0.0.1", "port": port}}},
		"inbounds":  []any{map[string]any{"protocol": "tun"}, map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": socksPort}},
		"outbounds": []any{map[string]any{"protocol": "freedom", "tag": "direct"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	owned, err := WindowsTunnelConfig(input, "elarni-fixture")
	if err != nil {
		t.Fatal(err)
	}
	var profile map[string]any
	if err := json.Unmarshal(owned, &profile); err != nil {
		t.Fatal(err)
	}
	profile["inbounds"].([]any)[0] = map[string]any{"tag": "elarni-tun", "protocol": "dokodemo-door", "listen": "127.0.0.1", "port": tunPort,
		"settings": map[string]any{"address": TunDNS4, "port": 53, "network": "tcp,udp"}}
	_, stop := startTrafficCore(t, profile)
	defer stop()
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(tunPort)), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(8 * time.Second))
	query, err := (&dnsmessage.Message{Header: dnsmessage.Header{ID: 7, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("big.example."), Type: dnsmessage.TypeTXT, Class: dnsmessage.ClassINET}}}).Pack()
	if err != nil {
		t.Fatal(err)
	}
	binary.Write(conn, binary.BigEndian, uint16(len(query)))
	conn.Write(query)
	var size uint16
	if err := binary.Read(conn, binary.BigEndian, &size); err != nil {
		t.Fatal("no TCP DNS reply:", err)
	}
	packet := make([]byte, size)
	if _, err := io.ReadFull(conn, packet); err != nil {
		t.Fatal(err)
	}
	var answer dnsmessage.Message
	if err := answer.Unpack(packet); err != nil {
		t.Fatal(err)
	}
	if answer.Truncated || len(answer.Answers) != 20 {
		t.Errorf("TCP query answered with TC=%v and %d records, want the full answer", answer.Truncated, len(answer.Answers))
	}
}

// A resolver that skips fallback serves only its own domains (often a domestic one, outside
// the proxy), so other names' SRV, TXT and the rest must not go to it; the Rust compiler's
// forward target agrees.
func TestWindowsTunnelDNSForwardSkipsDomainOnlyResolvers(t *testing.T) {
	address, port, _ := dnsForwardTarget([]any{
		map[string]any{"address": "77.88.8.8", "domains": []any{"domain:ru"}, "skipFallback": true},
		"https://1.1.1.1/dns-query",
	})
	if address != "1.1.1.1" || port != 53 {
		t.Fatalf("forward target %s:%d, want 1.1.1.1:53", address, port)
	}
}
