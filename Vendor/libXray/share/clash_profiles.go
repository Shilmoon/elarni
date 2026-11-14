package share

import (
	"encoding/json"
	"fmt"
	"net"
	"reflect"
	"slices"
	"strings"

	"github.com/xtls/xray-core/infra/conf"
	"gopkg.in/yaml.v3"
)

type clashGroup struct {
	Name     string   `yaml:"name" json:"name"`
	Type     string   `yaml:"type" json:"type"`
	Options  []string `yaml:"proxies" json:"options"`
	Selected string   `yaml:"selected" json:"selected"`
}

func importClashProfiles(text string) (*ClientImport, error) {
	var top map[string]yaml.Node
	if yaml.Unmarshal([]byte(text), &top) != nil {
		return nil, fmt.Errorf("invalid Clash profile")
	}
	for key := range top {
		switch key {
		case "proxies", "proxy-groups", "rules", "dns", "mode", "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "bind-address", "log-level", "external-controller", "external-ui", "secret":
		default:
			return nil, fmt.Errorf("unsupported Clash top-level field %s", key)
		}
	}
	var source struct {
		Proxies []yaml.Node    `yaml:"proxies"`
		Groups  []clashGroup   `yaml:"proxy-groups"`
		Rules   []string       `yaml:"rules"`
		DNS     map[string]any `yaml:"dns"`
		Mode    string         `yaml:"mode"`
	}
	if err := yaml.Unmarshal([]byte(text), &source); err != nil || len(source.Proxies) == 0 || len(source.Proxies) > 1024 {
		return nil, fmt.Errorf("invalid Clash profile")
	}
	// Global mode sends everything through the selected proxy: the file's rules do not apply.
	global := source.Mode == "global"
	if source.Mode != "" && source.Mode != "rule" && !global {
		return nil, fmt.Errorf("unsupported Clash mode")
	}
	if groups, ok := top["proxy-groups"]; ok {
		var fields []map[string]any
		if groups.Decode(&fields) != nil {
			return nil, fmt.Errorf("invalid Clash groups")
		}
		for _, group := range fields {
			for key := range group {
				if key != "name" && key != "type" && key != "proxies" && key != "selected" {
					return nil, fmt.Errorf("unsupported Clash group field %s", key)
				}
			}
		}
	}
	// Each proxy is decoded separately, which resets yaml.v3's alias limit, so one
	// anchor reused by every proxy needs a cap over the whole list.
	budget := maxClashExpandedNodes
	for i := range source.Proxies {
		if !clashNodesWithin(&source.Proxies[i], &budget) {
			return nil, fmt.Errorf("invalid Clash profile: aliases expand too far")
		}
	}
	outbounds := []map[string]any{}
	names := map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true}
	var skipped skippedMembers
	dropped := map[string]bool{}
	for _, node := range source.Proxies {
		outbound, err := clashClientOutbound(node)
		if err == nil {
			// Checked alone too, so a proxy the core refuses is skipped instead of failing the file.
			raw, _ := json.Marshal(map[string]any{"outbounds": []any{outbound}})
			if validateClientProfile(raw) != nil {
				err = fmt.Errorf("invalid Clash client settings")
			}
		}
		if err != nil {
			var fields map[string]any
			_ = node.Decode(&fields)
			name, _ := fields["name"].(string)
			kind, _ := fields["type"].(string)
			skipped.add(name, kind, "clash", err)
			if name != "" {
				dropped[name] = true
			}
			continue
		}
		name, _ := outbound["tag"].(string)
		if name == "" || names[name] {
			return nil, fmt.Errorf("duplicate or empty Clash proxy name")
		}
		names[name] = true
		outbounds = append(outbounds, outbound)
	}
	if len(outbounds) == 0 {
		return nil, skipped.first
	}
	for name := range names {
		delete(dropped, name) // a kept proxy of the same name stays reachable
	}
	for _, group := range source.Groups {
		if group.Name == "" || names[group.Name] || dropped[group.Name] || len(group.Options) == 0 {
			return nil, fmt.Errorf("invalid Clash group")
		}
		names[group.Name] = true
	}
	for _, group := range source.Groups {
		if group.Type != "select" {
			return nil, fmt.Errorf("unsupported Clash group type %s", group.Type)
		}
	}
	groups := pruneClashGroups(source.Groups, dropped, names)
	for i := range groups {
		group := &groups[i]
		for _, option := range group.Options {
			if !names[option] {
				return nil, fmt.Errorf("Clash group refers to a missing proxy")
			}
		}
		if group.Selected == "" {
			group.Selected = group.Options[0]
		}
		// Group aliases are resolved from the selected member by the profile compiler.
		outbounds = append(outbounds, map[string]any{"tag": group.Name, "protocol": "blackhole", "settings": map[string]any{}})
	}
	outbounds = append(outbounds, map[string]any{"tag": "DIRECT", "protocol": "freedom", "settings": map[string]any{}},
		map[string]any{"tag": "REJECT", "protocol": "blackhole", "settings": map[string]any{}},
		map[string]any{"tag": "REJECT-DROP", "protocol": "blackhole", "settings": map[string]any{}})
	root := map[string]any{"outbounds": outbounds, "remarks": "Clash profile"}
	if len(groups) > 0 {
		root["elarniGroups"] = groups
	}
	rules := []map[string]any{}
	for _, rule := range source.Rules {
		if global {
			break
		}
		converted, err := clashRoutingRule(rule, names)
		if err != nil {
			// The route a rule to a skipped proxy meant is gone; the file fails as that proxy did.
			if parts := strings.Split(rule, ","); dropped[strings.TrimSpace(parts[len(parts)-1])] {
				return nil, skipped.first
			}
			return nil, err
		}
		rules = append(rules, converted)
	}
	if len(rules) > 0 {
		root["routing"] = map[string]any{"domainStrategy": "IPOnDemand", "rules": rules}
	}
	if len(source.DNS) > 0 {
		dns, err := clashDNS(source.DNS)
		if err != nil {
			return nil, err
		}
		root["dns"] = dns
	}
	raw, err := json.Marshal(root)
	if err != nil || validateClientProfile(raw) != nil {
		return nil, fmt.Errorf("invalid Clash client settings")
	}
	result := &ClientImport{Profiles: []ClientProfile{{Format: "xrayProfile", Name: "Clash profile", Config: raw}}}
	skipped.report(result)
	return result, nil
}

// pruneClashGroups takes skipped proxies out of the groups, and a group they leave empty out of the
// groups that name it, until none empties. A selection of a dropped member falls back to the first.
func pruneClashGroups(groups []clashGroup, dropped, names map[string]bool) []clashGroup {
	for emptied := len(dropped) > 0; emptied; {
		emptied = false
		kept := groups[:0:0]
		for _, group := range groups {
			group.Options = slices.DeleteFunc(slices.Clone(group.Options), func(option string) bool { return dropped[option] })
			if len(group.Options) == 0 {
				dropped[group.Name], emptied = true, true
				delete(names, group.Name)
				continue
			}
			if dropped[group.Selected] {
				group.Selected = ""
			}
			kept = append(kept, group)
		}
		groups = kept
	}
	return groups
}

// About 250 nodes for each of the 1024 proxies a profile may hold.
const maxClashExpandedNodes = 250_000

// clashNodesWithin counts node's tree with aliases expanded against budget.
func clashNodesWithin(node *yaml.Node, budget *int) bool {
	pending := []*yaml.Node{node}
	for len(pending) > 0 {
		node = pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if *budget--; *budget < 0 {
			return false
		}
		if node.Kind == yaml.AliasNode && node.Alias != nil {
			pending = append(pending, node.Alias)
		}
		// Each queued node is charged when popped, so a queue longer than the budget
		// is bound to fail; checking first bounds it even for self-referencing aliases.
		if len(pending)+len(node.Content) > *budget {
			return false
		}
		pending = append(pending, node.Content...)
	}
	return true
}

func clashClientOutbound(node yaml.Node) (map[string]any, error) {
	var proxy ClashProxy
	var fields map[string]any
	if node.Decode(&proxy) != nil || node.Decode(&fields) != nil || proxy.Server == "" || proxy.Port == 0 {
		return nil, fmt.Errorf("invalid Clash proxy")
	}
	known := map[string]bool{"ip-version": true, "pin-sha256": true, "http-upgrade-opts": true, "alterId": true, "packet-encoding": true,
		"private-key": true, "public-key": true, "pre-shared-key": true, "ip": true, "ipv6": true, "mtu": true, "dns": true, "persistent-keepalive": true, "allowed-ips": true, "reserved": true}
	typ := reflect.TypeOf(proxy)
	for i := 0; i < typ.NumField(); i++ {
		known[strings.Split(typ.Field(i).Tag.Get("yaml"), ",")[0]] = true
	}
	for key := range fields {
		if !known[key] {
			return nil, fmt.Errorf("unsupported Clash proxy field %s", key)
		}
	}
	if err := validateClashSecurityOptions(fields); err != nil {
		return nil, err
	}
	if proxy.UdpOverTcp {
		return nil, fmt.Errorf("unsupported Clash UDP-over-TCP framing; use an Xray JSON profile")
	}
	if alterID, ok := fields["alterId"]; ok && fmt.Sprint(alterID) != "0" {
		return nil, fmt.Errorf("unsupported Clash legacy VMess alterId")
	}
	// Xray carries VLESS and VMess UDP as XUDP; another encoding would not reach the server.
	if encoding, ok := fields["packet-encoding"]; ok && encoding != nil && encoding != "" && encoding != "xudp" {
		return nil, fmt.Errorf("unsupported Clash packet encoding")
	}
	var outbound map[string]any
	if proxy.Type == "wireguard" {
		for _, value := range fields {
			if text, ok := value.(string); ok && strings.ContainsAny(text, "\r\n") {
				return nil, fmt.Errorf("invalid Clash WireGuard field")
			}
		}
		config := "[Interface]\nPrivateKey=" + clashString(fields, "private-key") + "\n"
		addresses := []string{}
		for _, key := range []string{"ip", "ipv6"} {
			if value := clashString(fields, key); value != "" {
				addresses = append(addresses, value)
			}
		}
		config += "Address=" + strings.Join(addresses, ",") + "\n"
		if mtu, ok := fields["mtu"]; ok {
			config += fmt.Sprint("MTU=", mtu, "\n")
		}
		if dns, ok := fields["dns"].([]any); ok {
			servers := []string{}
			for _, server := range dns {
				value, ok := server.(string)
				if !ok || strings.ContainsAny(value, "\r\n#;") {
					return nil, fmt.Errorf("invalid WireGuard DNS")
				}
				servers = append(servers, value)
			}
			config += "DNS=" + strings.Join(servers, ",") + "\n"
		}
		config += "[Peer]\nPublicKey=" + clashString(fields, "public-key") + "\nEndpoint=" + net.JoinHostPort(proxy.Server, fmt.Sprint(proxy.Port)) + "\n"
		if key := clashString(fields, "pre-shared-key"); key != "" {
			config += "PresharedKey=" + key + "\n"
		}
		if keepalive, ok := fields["persistent-keepalive"]; ok {
			config += fmt.Sprint("PersistentKeepalive=", keepalive, "\n")
		}
		if prefixes, ok := fields["allowed-ips"].([]any); ok {
			values := []string{}
			for _, item := range prefixes {
				value, ok := item.(string)
				if !ok || strings.ContainsAny(value, "\r\n") {
					return nil, fmt.Errorf("invalid WireGuard allowed IP")
				}
				values = append(values, value)
			}
			config += "AllowedIPs=" + strings.Join(values, ",") + "\n"
		}
		profile, err := importWireGuard(config, false, proxy.Name)
		if err != nil {
			return nil, err
		}
		var root map[string]any
		json.Unmarshal(profile.Config, &root)
		outbound = root["outbounds"].([]any)[0].(map[string]any)
		if reserved, ok := fields["reserved"]; ok {
			outbound["settings"].(map[string]any)["reserved"] = reserved
		}
	} else if proxy.Type == "http" {
		outbound = map[string]any{"protocol": "http", "settings": map[string]any{"address": proxy.Server, "port": proxy.Port, "user": proxy.Username, "pass": proxy.Password}}
		stream, err := proxy.streamSettings(conf.OutboundDetourConfig{Protocol: "http"})
		if err != nil {
			return nil, err
		}
		raw, _ := json.Marshal(stream)
		var value map[string]any
		json.Unmarshal(raw, &value)
		outbound["streamSettings"] = value
	} else {
		converted, err := proxy.outbound()
		if err != nil {
			return nil, fmt.Errorf("unsupported Clash proxy type %s", proxy.Type)
		}
		converted.SendThrough = nil
		raw, err := json.Marshal(converted)
		if err != nil {
			return nil, err
		}
		json.Unmarshal(raw, &outbound)
	}
	outbound["tag"] = proxy.Name
	if version := clashString(fields, "ip-version"); version != "" {
		strategies := map[string]string{"dual": "AsIs", "ipv4": "ForceIPv4", "ipv6": "ForceIPv6", "ipv4-prefer": "UseIPv4v6", "ipv6-prefer": "UseIPv6v4"}
		strategy, ok := strategies[version]
		if !ok {
			return nil, fmt.Errorf("invalid Clash IP version")
		}
		outbound["targetStrategy"] = strategy
	}
	stream, _ := outbound["streamSettings"].(map[string]any)
	if (proxy.Network == "ws" || proxy.Network == "httpupgrade" || proxy.Network == "xhttp") && stream == nil {
		return nil, fmt.Errorf("incompatible Clash transport")
	}
	if proxy.Network == "ws" {
		if opts, ok := fields["ws-opts"].(map[string]any); ok {
			settings, _ := stream["wsSettings"].(map[string]any)
			if settings == nil {
				return nil, fmt.Errorf("incompatible Clash WebSocket settings")
			}
			for key, value := range opts {
				switch key {
				case "path":
					settings["path"] = value
				case "headers":
					settings["headers"] = value
				default:
					return nil, fmt.Errorf("unsupported Clash WebSocket field")
				}
			}
		}
	}
	if proxy.Network == "httpupgrade" {
		opts, _ := fields["http-upgrade-opts"].(map[string]any)
		for key := range opts {
			if key != "path" && key != "headers" {
				return nil, fmt.Errorf("unsupported Clash HTTPUpgrade field")
			}
		}
		settings := map[string]any{"path": opts["path"]}
		if headers, ok := opts["headers"].(map[string]any); ok {
			remaining := map[string]any{}
			for key, value := range headers {
				if strings.EqualFold(key, "host") {
					host, ok := value.(string)
					if !ok {
						return nil, fmt.Errorf("invalid Clash HTTPUpgrade host")
					}
					if existing, exists := settings["host"]; exists && existing != host {
						return nil, fmt.Errorf("conflicting Clash HTTPUpgrade hosts")
					}
					settings["host"] = host
				} else {
					remaining[key] = value
				}
			}
			settings["headers"] = remaining
		}
		stream["httpupgradeSettings"] = settings
	}
	if pin := clashString(fields, "pin-sha256"); pin != "" {
		tls, ok := stream["tlsSettings"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("certificate pin requires TLS")
		}
		tls["pinnedPeerCertSha256"] = pin
	}
	if proxy.Network == "xhttp" {
		opts, ok := fields["xhttp-opts"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("missing Clash XHTTP options")
		}
		xhttp, err := clashXHTTP(opts)
		if err != nil {
			return nil, err
		}
		if download, ok := opts["download-settings"].(map[string]any); ok {
			if _, nested := download["download-settings"]; nested {
				return nil, fmt.Errorf("nested XHTTP download settings are unsupported")
			}
			if err := validateClashSecurityOptions(download); err != nil {
				return nil, err
			}
			encoded, err := yaml.Marshal(download)
			if err != nil {
				return nil, err
			}
			var legacy ClashProxyXhttpOptsDownloadSettings
			if yaml.Unmarshal(encoded, &legacy) != nil {
				return nil, fmt.Errorf("invalid XHTTP download settings")
			}
			converted, err := parseXHTTPDownloadSettings(&legacy)
			if err != nil {
				return nil, err
			}
			raw, _ := json.Marshal(converted)
			var down map[string]any
			json.Unmarshal(raw, &down)
			transport := map[string]any{}
			for key, value := range download {
				switch key {
				case "server", "port", "tls", "alpn", "ech-opts", "reality-opts", "skip-cert-verify", "fingerprint", "servername", "client-fingerprint", "pin-sha256":
				default:
					transport[key] = value
				}
			}
			details, err := clashXHTTP(transport)
			if err != nil {
				return nil, err
			}
			down["xhttpSettings"] = details
			if pin := clashString(download, "pin-sha256"); pin != "" {
				tls, ok := down["tlsSettings"].(map[string]any)
				if !ok {
					return nil, fmt.Errorf("download pin requires TLS")
				}
				tls["pinnedPeerCertSha256"] = pin
			}
			xhttp["downloadSettings"] = down
		}
		stream["xhttpSettings"] = xhttp
	}
	return outbound, nil
}

func validateClashSecurityOptions(fields map[string]any) error {
	for name, allowed := range map[string]string{
		"ech-opts": "enable config", "reality-opts": "public-key short-id",
		"grpc-opts": "grpc-service-name", "plugin-opts": "mode tls fingerprint ech-opts skip-cert-verify host path mux",
	} {
		raw, present := fields[name]
		if !present {
			continue
		}
		options, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("invalid Clash %s", name)
		}
		for key := range options {
			if !slices.Contains(strings.Fields(allowed), key) {
				return fmt.Errorf("unsupported Clash %s field %s", name, key)
			}
		}
		if name == "plugin-opts" {
			if enabled, _ := options["mux"].(bool); enabled {
				return fmt.Errorf("unsupported Clash plugin multiplexing")
			}
			if err := validateClashSecurityOptions(options); err != nil {
				return err
			}
		}
	}
	return nil
}

func clashString(fields map[string]any, key string) string {
	value, _ := fields[key].(string)
	return value
}

func clashXHTTP(opts map[string]any) (map[string]any, error) {
	fields := map[string]string{"path": "path", "host": "host", "mode": "mode", "headers": "headers", "no-grpc-header": "noGRPCHeader", "x-padding-bytes": "xPaddingBytes",
		"uplink-http-method": "uplinkHTTPMethod", "session-id-placement": "sessionIDPlacement", "session-id-key": "sessionIDKey", "session-id-table": "sessionIDTable", "session-id-length": "sessionIDLength",
		"seq-placement": "seqPlacement", "seq-key": "seqKey", "uplink-data-placement": "uplinkDataPlacement", "uplink-data-key": "uplinkDataKey", "uplink-chunk-size": "uplinkChunkSize",
		"sc-max-each-post-bytes": "scMaxEachPostBytes", "sc-min-posts-interval-ms": "scMinPostsIntervalMs", "x-padding-obfs-mode": "xPaddingObfsMode", "x-padding-key": "xPaddingKey",
		"x-padding-header": "xPaddingHeader", "x-padding-placement": "xPaddingPlacement", "x-padding-method": "xPaddingMethod"}
	result := map[string]any{}
	for key, value := range opts {
		if key == "download-settings" {
			continue
		}
		if field, ok := fields[key]; ok {
			result[field] = value
			continue
		}
		if key == "reuse-settings" {
			reuse, ok := value.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("invalid Clash XHTTP reuse settings")
			}
			xmux := map[string]any{}
			for name, value := range reuse {
				field, ok := map[string]string{"max-concurrency": "maxConcurrency", "max-connections": "maxConnections", "c-max-reuse-times": "cMaxReuseTimes", "h-max-request-times": "hMaxRequestTimes", "h-max-reusable-secs": "hMaxReusableSecs", "h-keep-alive-period": "hKeepAlivePeriod"}[name]
				if !ok {
					return nil, fmt.Errorf("unsupported XHTTP reuse field")
				}
				xmux[field] = value
			}
			result["xmux"] = xmux
			continue
		}
		return nil, fmt.Errorf("unsupported Clash XHTTP field %s", key)
	}
	return result, nil
}

func clashRoutingRule(text string, names map[string]bool) (map[string]any, error) {
	parts := strings.Split(text, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	if len(parts) > 0 && parts[len(parts)-1] == "no-resolve" {
		return nil, fmt.Errorf("unsupported Clash per-rule no-resolve; use an Xray JSON profile")
	}
	if len(parts) < 2 || !names[parts[len(parts)-1]] {
		return nil, fmt.Errorf("Clash rule has a missing target")
	}
	rule := map[string]any{"type": "field", "outboundTag": parts[len(parts)-1]}
	if parts[0] == "MATCH" && len(parts) == 2 {
		rule["network"] = "tcp,udp"
		return rule, nil
	}
	if len(parts) != 3 {
		return nil, fmt.Errorf("unsupported Clash rule shape")
	}
	switch parts[0] {
	case "DOMAIN":
		rule["domain"] = []string{"full:" + parts[1]}
	case "DOMAIN-SUFFIX":
		rule["domain"] = []string{"domain:" + parts[1]}
	case "DOMAIN-KEYWORD":
		rule["domain"] = []string{parts[1]}
	case "DOMAIN-REGEX":
		rule["domain"] = []string{"regexp:" + parts[1]}
	case "GEOSITE":
		rule["domain"] = []string{"geosite:" + parts[1]}
	case "GEOIP":
		// Clash's LAN is the private ranges, which geofiles name "private".
		if strings.EqualFold(parts[1], "LAN") {
			parts[1] = "private"
		}
		rule["ip"] = []string{"geoip:" + parts[1]}
	case "IP-CIDR", "IP-CIDR6":
		rule["ip"] = []string{parts[1]}
	case "SRC-IP-CIDR":
		rule["source"] = []string{parts[1]}
	case "DST-PORT":
		rule["port"] = parts[1]
	case "SRC-PORT":
		rule["sourcePort"] = parts[1]
	case "NETWORK":
		rule["network"] = strings.ToLower(parts[1])
	default:
		return nil, fmt.Errorf("unsupported Clash rule %s", parts[0])
	}
	return rule, nil
}

func clashDNS(source map[string]any) (map[string]any, error) {
	if enabled, ok := source["enable"].(bool); ok && !enabled {
		return nil, nil
	}
	result := map[string]any{}
	servers, ok := source["nameserver"].([]any)
	if !ok || len(servers) == 0 {
		return nil, fmt.Errorf("Clash DNS requires nameservers")
	}
	result["servers"] = servers
	if ipv6, ok := source["ipv6"].(bool); ok && !ipv6 {
		result["queryStrategy"] = "UseIPv4"
	}
	for key := range source {
		switch key {
		case "nameserver", "enable", "ipv6", "listen":
		// Settings of Mihomo's own DNS listener, which this app does not run.
		case "use-hosts", "enhanced-mode", "fake-ip-range", "fake-ip-filter", "default-nameserver":
		default:
			return nil, fmt.Errorf("unsupported Clash DNS field %s", key)
		}
	}
	return result, nil
}
