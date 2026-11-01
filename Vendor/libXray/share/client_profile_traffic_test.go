//go:build (darwin || android) && elarni_integration

package share

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	realityserver "github.com/xtls/reality"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
	routingsession "github.com/xtls/xray-core/features/routing/session"
	"github.com/xtls/xray-core/features/stats"
)

func TestCompiledProviderXHTTPFragmentationCarriesTraffic(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	for _, security := range []string{"tls", "reality"} {
		for _, split := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/download=%t", security, split), func(t *testing.T) {
				serverStream, clientStream := trafficTLS(t)
				if security == "reality" {
					private, err := ecdh.X25519().GenerateKey(rand.Reader)
					if err != nil {
						t.Fatal(err)
					}
					target := httptest.NewUnstartedServer(http.NotFoundHandler())
					target.EnableHTTP2 = true
					target.TLS = &tls.Config{CurvePreferences: []tls.CurveID{tls.X25519}, MinVersion: tls.VersionTLS13}
					target.StartTLS()
					t.Cleanup(target.Close)
					// Reuse the synthetic target policy from the existing REALITY fixture.
					for _, alpn := range []string{"0", "1", "2"} {
						key := target.Listener.Addr().String() + " example.com " + alpn
						realityserver.GlobalPostHandshakeRecordsLens.Store(key, []int{})
						t.Cleanup(func() { realityserver.GlobalPostHandshakeRecordsLens.Delete(key) })
					}
					serverStream = object{"security": "reality", "realitySettings": object{
						"target": target.Listener.Addr().String(), "serverNames": []string{"example.com"},
						"privateKey": base64.RawURLEncoding.EncodeToString(private.Bytes()), "shortIds": []string{"0123456789abcdef"}}}
					clientStream = object{"security": "reality", "realitySettings": object{
						"serverName": "example.com", "fingerprint": "chrome",
						"publicKey": base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes()), "shortId": "0123456789abcdef"}}
				}
				port := trafficPort(t)
				serverStream["network"], clientStream["network"] = "xhttp", "xhttp"
				serverStream["xhttpSettings"] = object{"path": "/fragment-fixture"}
				settings := object{"path": "/fragment-fixture", "mode": "auto"}
				if split {
					download := object{"address": "127.0.0.1", "port": port, "xhttpSettings": object{"path": "/fragment-fixture"}}
					for key, value := range clientStream {
						download[key] = value
					}
					settings["extra"] = object{"downloadSettings": download}
				}
				clientStream["xhttpSettings"] = settings
				_, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"},
					"inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless",
						"settings": object{"clients": []any{object{"id": id}}, "decryption": "none"}, "streamSettings": serverStream}},
					"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
				defer stopServer()
				raw, err := json.Marshal(object{"outbounds": []any{object{"tag": "provider", "protocol": "vless",
					"settings": object{"address": "127.0.0.1", "port": port, "id": id, "encryption": "none"}, "streamSettings": clientStream}},
					"stats": object{}, "policy": object{"system": object{"statsOutboundUplink": true}}})
				if err != nil {
					t.Fatal(err)
				}
				imported, err := ImportClientProfiles(string(raw))
				if err != nil {
					t.Fatal(err)
				}
				for _, enabled := range []bool{true, false} {
					compiled, err := compileElarniFFI("compileProfile", object{
						"profile": imported.Profiles[0].Config, "socksPort": trafficPort(t),
						"runtime": object{"fragmentationEnabled": enabled}})
					if err != nil {
						t.Fatal(err)
					}
					var config object
					if err := json.Unmarshal(compiled, &config); err != nil {
						t.Fatal(err)
					}
					client, stopClient := startTrafficCore(t, config)
					for _, address := range []string{"127.0.0.1", "::1"} {
						for _, network := range []string{"tcp", "udp"} {
							trafficRoundTrip(t, client, network, address)
						}
					}
					counter := client.GetFeature(stats.ManagerType()).(stats.Manager).GetCounter("outbound>>>elarni-fragment-0>>>traffic>>>uplink")
					if enabled && (counter == nil || counter.Value() == 0) {
						t.Fatal("traffic did not traverse the fragmentation helper")
					}
					if !enabled && counter != nil {
						t.Fatal("fragmentation helper survived disabling")
					}
					stopClient()
				}
			})
		}
	}
}

func TestCompiledProviderRoutingListsMatchIndependently(t *testing.T) {
	type object = map[string]any
	// Match the reported Happ shape without geofiles, credentials or external traffic.
	routes := object{"dnsServers": []string{"192.0.2.53"}, "fallbackAction": "proxy", "rules": []any{
		object{"action": "block", "domains": []string{"full:blocked.ru"}, "ips": []string{"192.0.2.9/32"}},
		object{"action": "proxy", "domains": []string{"full:proxy.ru"}, "ips": []string{"10.2.0.0/16"}},
		object{"action": "direct", "domains": []string{"domain:.ru", "domain:.su", "domain:.xn--p1ai", "full:exact.test"}, "ips": []string{"10.0.0.0/8", "2001:db8::/32"}},
	}}
	for _, operation := range []string{"compileOutbound", "compileProfile"} {
		t.Run(operation, func(t *testing.T) {
			outbound := object{"tag": "provider", "protocol": "vless", "settings": object{
				"address": "127.0.0.1", "port": 1, "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}}
			payload := object{"routes": routes, "socksPort": trafficPort(t), "packetBackend": "xrayTun"}
			if operation == "compileOutbound" {
				payload["outbound"] = outbound
			} else {
				payload["profile"] = object{"outbounds": []any{outbound}}
			}
			raw, err := compileElarniFFI(operation, payload)
			if err != nil {
				t.Fatal(err)
			}
			var config object
			if err := json.Unmarshal(raw, &config); err != nil {
				t.Fatal(err)
			}
			// Exercise both ingress tags in the actual router without opening an OS TUN.
			config["inbounds"] = []any{}
			client, stop := startTrafficCore(t, config)
			defer stop()
			router := client.GetFeature(routing.RouterType()).(routing.Router)
			for _, inbound := range []string{"elarni-socks", "elarni-tun"} {
				for _, network := range []net.Network{net.Network_TCP, net.Network_UDP} {
					for _, fixture := range []struct{ domain, ip, tag string }{
						{"fixture.ru", "198.51.100.8", "elarni-direct"},
						{"nested.fixture.su", "198.51.100.8", "elarni-direct"},
						{"fixture.xn--p1ai", "2001:db8:ffff::1", "elarni-direct"},
						{"", "10.1.2.3", "elarni-direct"},
						{"", "2001:db8::8", "elarni-direct"},
						{"blocked.ru", "198.51.100.8", "elarni-block"},
						{"fixture.ru", "192.0.2.9", "elarni-block"},
						{"proxy.ru", "10.1.2.3", "elarni-proxy"},
						{"fixture.ru", "10.2.1.1", "elarni-proxy"},
						{"exact.test", "198.51.100.8", "elarni-direct"},
						{"sub.exact.test", "198.51.100.8", "elarni-proxy"},
						{"fixture.ru.example", "198.51.100.8", "elarni-proxy"},
						{"fixture.notru", "198.51.100.8", "elarni-proxy"},
					} {
						ctx := &routingsession.Context{Inbound: &session.Inbound{Tag: inbound}, Outbound: &session.Outbound{
							Target: net.Destination{Network: network, Address: net.ParseAddress(fixture.ip), Port: 443}}}
						if fixture.domain != "" {
							ctx.Outbound.RouteTarget = net.Destination{Network: network, Address: net.DomainAddress(fixture.domain), Port: 443}
						}
						picked, err := router.PickRoute(ctx)
						if err != nil {
							t.Fatal(err)
						}
						if picked.GetOutboundTag() != fixture.tag {
							t.Errorf("%s %s %s/%s: got %s, want %s", inbound, network, fixture.domain, fixture.ip, picked.GetOutboundTag(), fixture.tag)
						}
					}
				}
			}
		})
	}
}

// A blocked default route makes loss of the provider's routing observable.
// The r selector would also match elarni-direct without exact expansion;
// only the provider outbound resolves these synthetic names using profile DNS.
func TestCompiledProviderDNSAndBalancerCarryTraffic(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	port := trafficPort(t)
	_, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"},
		"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": id}}, "decryption": "none"}}},
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
	defer stopServer()
	for _, providerStrategy := range []string{"", "AsIs"} {
		t.Run("resolvedIP/"+providerStrategy, func(t *testing.T) {
			providerRouting := object{"rules": []any{}}
			if providerStrategy != "" {
				providerRouting["domainStrategy"] = providerStrategy
			}
			// The provider blocks by default. Only resolving the synthetic
			// hostname for the app's IP rule permits these TCP/UDP replies.
			payload := object{"profile": object{
				"dns":     object{"hosts": object{"fixture4.test": "127.0.0.1", "fixture6.test": "::1"}, "servers": []string{"localhost"}},
				"routing": providerRouting, "outbounds": []any{object{"tag": "default", "protocol": "blackhole"}}},
				"socksPort": trafficPort(t), "routes": object{"domainStrategy": "IPOnDemand", "dnsServers": []string{"192.0.2.53"},
					"rules": []any{object{"action": "direct", "domains": []string{}, "ips": []string{"127.0.0.1/32", "::1/128"}}}}}
			// The direct outbound must also use the synthetic core DNS hosts.
			for _, family := range []struct{ preference, address, host string }{{"ipv4", "127.0.0.1", "fixture4.test"}, {"ipv6", "::1", "fixture6.test"}} {
				payload["preferredIp"] = family.preference
				compiled, err := compileElarniFFI("compileProfile", payload)
				if err != nil {
					t.Fatal(err)
				}
				var config object
				if err := json.Unmarshal(compiled, &config); err != nil {
					t.Fatal(err)
				}
				client, stopClient := startTrafficCore(t, config)
				for _, network := range []string{"tcp", "udp"} {
					trafficRoundTripFromInbound(t, client, network, family.address, "elarni-socks", family.host)
				}
				stopClient()
			}
		})
	}
	profile := object{"dns": object{"hosts": object{"fixture4.test": "127.0.0.1", "fixture6.test": "::1"}, "servers": []any{object{"address": "127.0.0.1", "port": trafficPort(t)}}},
		"outbounds": []any{object{"tag": "default", "protocol": "blackhole"}, object{"tag": "r", "protocol": "vless", "targetStrategy": "UseIP", "settings": object{"address": "127.0.0.1", "port": port, "id": id, "encryption": "none"}}},
		"routing": object{"balancers": []any{object{"tag": "pool", "selector": []string{"r"}, "strategy": object{"type": "random"}}},
			"rules": []any{object{"type": "field", "network": "tcp,udp", "balancerTag": "pool"}}}}
	raw, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	imported, err := ImportClientProfiles(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	for cycle := 0; cycle < 2; cycle++ {
		compiled, err := compileElarniProfileFFI(imported.Profiles[0].Config, trafficPort(t))
		if err != nil {
			t.Fatal(err)
		}
		var config object
		if err := json.Unmarshal(compiled, &config); err != nil {
			t.Fatal(err)
		}
		client, stopClient := startTrafficCore(t, config)
		for _, network := range []string{"tcp", "udp"} {
			trafficRoundTrip(t, client, network, "127.0.0.1", "fixture4.test")
			trafficRoundTrip(t, client, network, "::1", "fixture6.test")
		}
		stopClient()
	}
}

func TestCompiledProviderChainsTraverseBothHops(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	entryPort, exitPort := trafficPort(t), trafficPort(t)
	inbounds := []any{}
	for _, endpoint := range []struct {
		tag  string
		port int
	}{{"entry", entryPort}, {"exit", exitPort}} {
		inbounds = append(inbounds, object{"tag": endpoint.tag, "listen": "127.0.0.1", "port": endpoint.port, "protocol": "vless",
			"settings": object{"clients": []any{object{"id": id}}, "decryption": "none"}})
	}
	server, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"}, "stats": object{},
		"policy": object{"system": object{"statsInboundUplink": true}}, "inbounds": inbounds,
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
	defer stopServer()
	manager := server.GetFeature(stats.ManagerType()).(stats.Manager)
	for _, transportLayer := range []bool{false, true} {
		t.Run(fmt.Sprintf("transportLayer=%t", transportLayer), func(t *testing.T) {
			before := map[string]int64{}
			for _, tag := range []string{"entry", "exit"} {
				counter := manager.GetCounter("inbound>>>" + tag + ">>>traffic>>>uplink")
				if counter == nil {
					t.Fatal("missing server inbound counter")
				}
				before[tag] = counter.Value()
			}
			entry := object{"tag": "entry", "protocol": "vless", "settings": object{"address": "127.0.0.1", "port": entryPort, "id": id, "encryption": "none"}}
			exit := object{"tag": "exit", "protocol": "vless", "settings": object{"address": "127.0.0.1", "port": exitPort, "id": id, "encryption": "none"}, "proxySettings": object{"tag": "entry", "transportLayer": transportLayer}}
			raw, err := json.Marshal(object{"outbounds": []any{exit, entry}})
			if err != nil {
				t.Fatal(err)
			}
			imported, err := ImportClientProfiles(string(raw))
			if err != nil {
				t.Fatal(err)
			}
			compiled, err := compileElarniProfileFFI(imported.Profiles[0].Config, trafficPort(t))
			if err != nil {
				t.Fatal(err)
			}
			var config object
			if err := json.Unmarshal(compiled, &config); err != nil {
				t.Fatal(err)
			}
			client, stopClient := startTrafficCore(t, config)
			for _, network := range []string{"tcp", "udp"} {
				trafficRoundTrip(t, client, network, "127.0.0.1")
				trafficRoundTrip(t, client, network, "::1")
			}
			stopClient()
			for _, tag := range []string{"entry", "exit"} {
				if manager.GetCounter("inbound>>>"+tag+">>>traffic>>>uplink").Value() <= before[tag] {
					t.Fatalf("chain bypassed %s hop", tag)
				}
			}
		})
	}
}
