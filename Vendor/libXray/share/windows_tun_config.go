package share

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The desktop TUN's own addresses. CGNAT 100.64/10 is Tailscale's (its firewall drops
// those sources on other interfaces) and private ranges are LANs and Docker networks;
// the documentation range 198.51.100.0/24 (RFC 5737) appears on no real network.
const (
	TunGateway4 = "198.51.100.254/30"
	TunDNS4     = "198.51.100.253"
	TunGateway6 = "fd76:6f75:7465::2/126"
	TunDNS6     = "fd76:6f75:7465::1"
)

// jsonKey folds a key the way encoding/json matches field names, which also
// treats U+017F (long s) as s and U+212A (Kelvin sign) as k.
func jsonKey(key string) string {
	return strings.ToLower(strings.Map(func(r rune) rune {
		for {
			next := unicode.SimpleFold(r)
			if next <= r {
				return next
			}
			r = next
		}
	}, key))
}

func isASCII(text string) bool {
	for i := 0; i < len(text); i++ {
		if text[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// WindowsTunnelConfig is an independent elevation boundary. It accepts the
// compiled client graph but reconstructs every privileged local resource.
func WindowsTunnelConfig(raw []byte, adapter string, policies ...*WindowsRoutePolicy) ([]byte, error) {
	invalid := errors.New("invalid_vpn_config")
	if len(policies) > 1 {
		return nil, invalid
	}
	var policy *WindowsRoutePolicy
	if len(policies) == 1 {
		policy = policies[0]
	}
	routes, err := WindowsRoutes(policy)
	if err != nil {
		return nil, err
	}
	routeStrings := make([]string, len(routes))
	for i, p := range routes {
		routeStrings[i] = p.String()
	}
	if len(raw) == 0 || len(raw) > 8*1024*1024 || adapter == "" {
		return nil, invalid
	}
	var config map[string]any
	if json.Unmarshal(raw, &config) != nil || validateProfileFiles(config, "") != nil {
		return nil, invalid
	}
	allowed := map[string]bool{"log": true, "inbounds": true, "outbounds": true, "dns": true, "routing": true,
		"policy": true, "stats": true, "observatory": true, "burstObservatory": true, "reverse": true, "fakeDns": true, "fakedns": true}
	for key := range config {
		if !allowed[key] {
			return nil, invalid
		}
	}
	// Xray reads the named geodata file for each of these prefixes, in values and in DNS
	// host keys, and IP rules may negate one with any number of '!'.
	externalGeodata := func(text string) bool {
		text = strings.TrimLeft(text, "!")
		// ext: may name either bundled file: Xray reads it as geoip in IP rules.
		if rest, found := strings.CutPrefix(text, "ext:"); found {
			return !strings.HasPrefix(rest, "geosite.dat:") && !strings.HasPrefix(rest, "geoip.dat:")
		}
		for prefix, bundled := range map[string]string{"ext-site:": "geosite.dat:", "ext-domain:": "geosite.dat:", "ext-ip:": "geoip.dat:"} {
			if rest, found := strings.CutPrefix(text, prefix); found && !strings.HasPrefix(rest, bundled) {
				return true
			}
		}
		return false
	}
	var safe func(any) bool
	safe = func(value any) bool {
		switch item := value.(type) {
		case []any:
			for _, child := range item {
				if !safe(child) {
					return false
				}
			}
		case map[string]any:
			seen := map[string]bool{}
			for key, child := range item {
				// Xray keeps the last of two keys it folds together, and a non-ASCII key
				// that folds to ASCII names a field the checks below would not see.
				folded := jsonKey(key)
				if seen[folded] || !isASCII(key) && isASCII(folded) || externalGeodata(key) {
					return false
				}
				seen[folded] = true
				text, _ := child.(string)
				// Xray decodes keys case-insensitively, so this boundary must too.
				switch jsonKey(key) {
				case "masterkeylog", "certificatefile", "keyfile":
					if child != nil && child != "" {
						return false
					}
				case "webhook":
					if child != nil {
						return false
					}
				case "customsockopt":
					// Raw setsockopt in a privileged helper bypasses the interface ban.
					if values, _ := child.([]any); child != nil && (values == nil || len(values) != 0) {
						return false
					}
				case "usesystemhosts":
					if child != false {
						return false
					}
				case "network":
					if strings.EqualFold(text, "unix") {
						return false
					}
				case "address", "endpoint":
					if strings.HasPrefix(text, "/") || strings.HasPrefix(text, `\`) || strings.HasPrefix(text, "unix:") {
						return false
					}
				case "interface":
					if text != "" {
						return false
					}
				case "tproxy":
					if text != "" && text != "off" {
						return false
					}
				}
				if !safe(child) {
					return false
				}
			}
		case string:
			if externalGeodata(item) {
				return false
			}
		}
		return true
	}
	if !safe(config) {
		return nil, invalid
	}
	outbounds, ok := config["outbounds"].([]any)
	if !ok || len(outbounds) == 0 || len(outbounds) > 1024 {
		return nil, invalid
	}
	protocols := map[string]bool{"vless": true, "vmess": true, "shadowsocks": true, "trojan": true, "socks": true, "http": true,
		"hysteria": true, "tuic": true, "wireguard": true, "amneziawg": true, "freedom": true, "blackhole": true, "dns": true, "loopback": true}
	for _, item := range outbounds {
		outbound, ok := item.(map[string]any)
		if !ok {
			return nil, invalid
		}
		protocol, _ := outbound["protocol"].(string)
		if !protocols[protocol] || outbound["tag"] == "elarni-windows-dns" || outbound["tag"] == "elarni-windows-dns-forward" {
			return nil, invalid
		}
		if protocol == "wireguard" || protocol == "amneziawg" {
			settings, ok := outbound["settings"].(map[string]any)
			if !ok {
				return nil, invalid
			}
			for key := range settings {
				// A folded duplicate that sorts later would override the forced value.
				if jsonKey(key) == "nokerneltun" {
					delete(settings, key)
				}
			}
			settings["noKernelTun"] = true
		}
	}
	inbounds, ok := config["inbounds"].([]any)
	if !ok || len(inbounds) < 2 || len(inbounds) > 3 {
		return nil, invalid
	}
	owned := []any{}
	var tunSniffing any
	seen := map[string]bool{}
	ports := map[float64]bool{}
	for _, item := range inbounds {
		inbound, ok := item.(map[string]any)
		if !ok {
			return nil, invalid
		}
		protocol, _ := inbound["protocol"].(string)
		if seen[protocol] {
			return nil, invalid
		}
		seen[protocol] = true
		if protocol == "tun" {
			tunSniffing = inbound["sniffing"]
			continue
		}
		port, ok := inbound["port"].(float64)
		listen, _ := inbound["listen"].(string)
		if !ok || port != float64(int(port)) || port < 1 || port > 65535 || ports[port] ||
			(protocol != "socks" && protocol != "http") || (listen != "127.0.0.1" && listen != "0.0.0.0") {
			return nil, invalid
		}
		ports[port] = true
		settings := map[string]any{}
		input, _ := inbound["settings"].(map[string]any)
		accounts, present := input["accounts"]
		if present {
			values, ok := accounts.([]any)
			if !ok || len(values) != 1 {
				return nil, invalid
			}
			account, ok := values[0].(map[string]any)
			if !ok {
				return nil, invalid
			}
			for _, key := range []string{"user", "pass"} {
				value, ok := account[key].(string)
				if !ok || len(value) == 0 || len(value) > 255 || strings.ContainsAny(value, "\r\n\x00") {
					return nil, invalid
				}
			}
			settings["accounts"] = []any{map[string]any{"user": account["user"], "pass": account["pass"]}}
		}
		if listen == "0.0.0.0" && !present {
			return nil, invalid
		}
		if protocol == "socks" {
			settings["auth"] = "noauth"
			if present {
				if input["auth"] != "password" {
					return nil, invalid
				}
				settings["auth"] = "password"
			} else if input["auth"] != nil && input["auth"] != "noauth" {
				return nil, invalid
			}
			settings["udp"] = true
		}
		owned = append(owned, map[string]any{"tag": "elarni-" + protocol, "protocol": protocol, "listen": listen, "port": port, "settings": settings,
			"sniffing": inbound["sniffing"]})
	}
	if !seen["tun"] || !seen["socks"] {
		return nil, invalid
	}
	// MTU 9000, as sing-box and the Android VpnService use: six times fewer packets through
	// Wintun, Windows TCP and gVisor per MB. Elarni's own sockets bypass the TUN, so the path MTU is unchanged.
	owned = append([]any{map[string]any{"tag": "elarni-tun", "port": 0, "protocol": "tun",
		"sniffing": tunSniffing,
		"settings": map[string]any{"name": adapter, "desc": "Elarni", "mtu": 9000,
			"gateway":                []string{TunGateway4, TunGateway6},
			"dns":                    []string{TunDNS4, TunDNS6},
			"autoSystemRoutingTable": routeStrings,
			"autoOutboundsInterface": ""}}}, owned...)
	config["inbounds"] = owned
	config["log"] = map[string]any{"loglevel": "none"}
	// DNS requests arriving from Windows use the profile's Xray DNS policy. Xray answers only
	// A and AAAA itself, so SRV, MX, TXT and the rest go to the profile's resolver along the
	// route its own queries take. HTTPS records stay empty: their address hints bypass FakeDNS.
	dns, _ := config["dns"].(map[string]any)
	dnsTag, _ := dns["tag"].(string)
	address, port, network := dnsForwardTarget(dns["servers"])
	config["outbounds"] = append(outbounds,
		map[string]any{"tag": "elarni-windows-dns-forward", "protocol": "loopback", "settings": map[string]any{"inboundTag": dnsTag}},
		// Linux renames the last outbound, so the DNS outbound stays last.
		map[string]any{"tag": "elarni-windows-dns", "protocol": "dns",
			"streamSettings": map[string]any{"sockopt": map[string]any{"dialerProxy": "elarni-windows-dns-forward"}},
			"settings": map[string]any{"address": address, "port": port, "network": network, "rules": []any{
				map[string]any{"action": "hijack", "qType": "1,28"},
				map[string]any{"action": "return", "qType": "64,65"},
				map[string]any{"action": "direct"}}}})
	routing, ok := config["routing"].(map[string]any)
	if !ok {
		routing = map[string]any{}
		config["routing"] = routing
	}
	rules, _ := routing["rules"].([]any)
	routing["rules"] = append([]any{map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "port": "53", "network": "tcp,udp", "outboundTag": "elarni-windows-dns"}}, rules...)
	return json.Marshal(config)
}

// dnsForwardTarget picks the first of Xray's DNS servers that has an IP address: a plain
// one, a tcp:// one, or the IP host of a DoH or DoQ URL on port 53, where the public
// resolvers that serve those by IP also answer. 1.1.1.1 otherwise. An empty network keeps
// each query's own, so a TCP retry of a truncated answer is not truncated again.
func dnsForwardTarget(servers any) (string, int, string) {
	list, _ := servers.([]any)
	for _, server := range list {
		address, _ := server.(string)
		port, network := 53, ""
		if object, ok := server.(map[string]any); ok {
			address, _ = object["address"].(string)
			if value, ok := object["port"].(float64); ok && value >= 1 && value <= 65535 && value == float64(int(value)) {
				port = int(value)
			}
		}
		if strings.Contains(address, "://") {
			parsed, err := url.Parse(address)
			if err != nil {
				continue
			}
			address, port = parsed.Hostname(), 53
			if strings.HasPrefix(strings.ToLower(parsed.Scheme), "tcp") {
				network = "tcp"
				if value, err := strconv.Atoi(parsed.Port()); err == nil && value >= 1 && value <= 65535 {
					port = value
				}
			}
		}
		if ip := net.ParseIP(address); ip != nil {
			return ip.String(), port, network
		}
	}
	return "1.1.1.1", 53, ""
}
