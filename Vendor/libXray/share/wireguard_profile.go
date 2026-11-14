package share

import (
	"bytes"
	"compress/zlib"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/infra/conf"
)

var amneziaFields = map[string]string{
	"jc": "jc", "jmin": "jmin", "jmax": "jmax",
	"s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
	"h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
	"i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
	"headerprotectionkey": "header_protection_key", "contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime": "rekey_after_time", "rekeytimeout": "rekey_timeout", "rejectaftertime": "reject_after_time",
	"keepalivetimeout": "keepalive_timeout", "maxhandshakeattempts": "max_handshake_attempts",
	"randomtrailers": "random_trailers", "disablecookies": "disable_cookies",
}

func importWireGuard(text string, forceAmnezia bool, name string) (ClientProfile, error) {
	settings := conf.WireGuardConfig{IsClient: true, NoKernelTun: true, Amnezia: map[string]string{}}
	var peer *conf.WireGuardPeerConfig
	var dns []string
	section := ""
	seen := map[string]bool{}
	interfaceSeen := false
	for index, line := range strings.Split(FixWindowsReturn(text), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		field, _, _ := strings.Cut(line, "=")
		field = strings.ToLower(strings.TrimSpace(field))
		// AWG permits separators between obfuscation tags; keep the full spec.
		if field != "i1" && field != "i2" && field != "i3" && field != "i4" && field != "i5" {
			line = strings.TrimSpace(strings.SplitN(strings.SplitN(line, "#", 2)[0], ";", 2)[0])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			switch strings.ToLower(line) {
			case "[interface]":
				if interfaceSeen {
					return ClientProfile{}, fmt.Errorf("duplicate WireGuard interface")
				}
				interfaceSeen, section = true, "interface"
			case "[peer]":
				if !interfaceSeen {
					return ClientProfile{}, fmt.Errorf("WireGuard peer precedes interface")
				}
				section = "peer"
				peer = &conf.WireGuardPeerConfig{}
				settings.Peers = append(settings.Peers, peer)
			default:
				return ClientProfile{}, fmt.Errorf("unsupported WireGuard section on line %d", index+1)
			}
			seen = map[string]bool{}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.TrimSpace(value)
		// wg-quick adds up repeated Address and DNS lines and wg repeated AllowedIPs (old wgcf writes
		// one Address line per family); any other key must say one thing.
		list := key == "allowedips" || (section == "interface" && (key == "address" || key == "dns"))
		if !ok || value == "" || (seen[key] && !list) || section == "" {
			return ClientProfile{}, fmt.Errorf("invalid WireGuard field on line %d", index+1)
		}
		seen[key] = true
		if section == "interface" {
			switch key {
			case "privatekey":
				settings.SecretKey = value
			case "address":
				settings.Address = append(settings.Address, commaValues(value)...)
			case "dns":
				dns = append(dns, commaValues(value)...)
			case "listenport":
				// A client's own port: Xray picks one.
			case "mtu":
				mtu, err := strconv.ParseInt(value, 10, 32)
				if err != nil {
					return ClientProfile{}, fmt.Errorf("invalid WireGuard MTU")
				}
				settings.MTU = int32(mtu)
			case "reserved":
				// v2rayN writes the three reserved bytes as "1,2,3".
				for _, part := range commaValues(value) {
					n, err := strconv.ParseUint(part, 10, 8)
					if err != nil {
						return ClientProfile{}, fmt.Errorf("invalid WireGuard reserved bytes")
					}
					settings.Reserved = append(settings.Reserved, byte(n))
				}
			default:
				field, ok := amneziaFields[key]
				if !ok {
					return ClientProfile{}, fmt.Errorf("unsupported WireGuard interface field %s", key)
				}
				if field == "header_protection_key" {
					var err error
					value, err = conf.ParseWireGuardKey(value)
					if err != nil {
						return ClientProfile{}, fmt.Errorf("invalid header protection key")
					}
				}
				if field == "random_trailers" || field == "disable_cookies" {
					switch strings.ToLower(value) {
					case "on", "yes":
						value = "true"
					case "off", "no":
						value = "false"
					}
				}
				settings.Amnezia[field] = value
			}
		} else {
			switch key {
			case "publickey":
				peer.PublicKey = value
			case "presharedkey":
				peer.PreSharedKey = value
			case "endpoint":
				peer.Endpoint = value
			case "allowedips":
				peer.AllowedIPs = append(peer.AllowedIPs, commaValues(value)...)
			case "persistentkeepalive":
				peer.KeepAliveRange = value
			default:
				return ClientProfile{}, fmt.Errorf("unsupported WireGuard peer field %s", key)
			}
		}
	}
	settings.IsAmnezia = forceAmnezia || len(settings.Amnezia) > 0
	settings.DNS = dns
	if !interfaceSeen || len(settings.Address) == 0 || len(settings.Peers) == 0 {
		return ClientProfile{}, fmt.Errorf("WireGuard requires interface addresses and peers")
	}
	if !settings.IsAmnezia {
		for _, peer := range settings.Peers {
			if peer.KeepAliveRange == "" {
				continue
			}
			n, err := strconv.ParseUint(peer.KeepAliveRange, 10, 16)
			if err != nil {
				return ClientProfile{}, fmt.Errorf("invalid WireGuard keepalive")
			}
			peer.KeepAlive, peer.KeepAliveRange = uint32(n), ""
		}
	}
	if _, err := settings.Build(); err != nil {
		return ClientProfile{}, fmt.Errorf("invalid WireGuard or AmneziaWG settings: %w", err)
	}
	protocol := "wireguard"
	if settings.IsAmnezia {
		protocol = "amneziawg"
	}
	root := map[string]any{"outbounds": []any{map[string]any{"tag": "proxy", "protocol": protocol, "settings": settings}}}
	if len(dns) > 0 {
		root["dns"] = map[string]any{"servers": dns}
	}
	raw, err := json.Marshal(root)
	if err != nil {
		return ClientProfile{}, err
	}
	if name == "" {
		name = strings.ToUpper(protocol[:1]) + protocol[1:]
	}
	return ClientProfile{Format: "xrayProfile", Name: name, Config: raw}, nil
}

func commaValues(value string) []string {
	values := strings.Split(value, ",")
	for i := range values {
		values[i] = strings.TrimSpace(values[i])
	}
	return values
}

// wireGuardText reports wg-quick text: its first line that is neither blank nor a comment is [Interface].
func wireGuardText(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		return strings.EqualFold(line, "[interface]")
	}
	return false
}

// maxAmneziaKey caps what an AmneziaVPN key may inflate to.
const maxAmneziaKey = 1 << 20

// amneziaContainers maps AmneziaVPN's WireGuard and AmneziaWG container names to the key their
// settings are kept under (client/core/utils/containers/containerUtils.cpp).
var amneziaContainers = map[string]string{"amnezia-awg": "awg", "amnezia-awg2": "awg", "amnezia-wireguard": "wireguard"}

// amneziaKeyConfig reads an AmneziaVPN key as its client exports one: Qt's qCompress of the server
// JSON, a 4-byte big-endian length before a zlib stream. It returns the wg-quick text of the default
// container (else of the first WireGuard or AmneziaWG one), whether that container is AmneziaWG, and
// the key's description.
func amneziaKeyConfig(data []byte) (string, bool, string, error) {
	invalid := fmt.Errorf("invalid AmneziaVPN key")
	if len(data) < 4 {
		return "", false, "", invalid
	}
	reader, err := zlib.NewReader(bytes.NewReader(data[4:]))
	if err != nil {
		return "", false, "", invalid
	}
	defer reader.Close()
	inflated, err := io.ReadAll(io.LimitReader(reader, maxAmneziaKey+1))
	if err != nil || len(inflated) > maxAmneziaKey {
		return "", false, "", invalid
	}
	var key struct {
		Containers       []map[string]json.RawMessage `json:"containers"`
		DefaultContainer string                       `json:"defaultContainer"`
		Description      string                       `json:"description"`
		DNS1             string                       `json:"dns1"`
		DNS2             string                       `json:"dns2"`
	}
	if json.Unmarshal(inflated, &key) != nil {
		return "", false, "", invalid
	}
	if key.DefaultContainer != "" && amneziaContainers[key.DefaultContainer] == "" {
		return "", false, "", fmt.Errorf("AmneziaVPN key's default protocol is not WireGuard or AmneziaWG")
	}
	var chosen map[string]json.RawMessage
	var chosenName string
	for _, container := range key.Containers {
		var name string
		_ = json.Unmarshal(container["container"], &name)
		if amneziaContainers[name] == "" || (chosen != nil && name != key.DefaultContainer) {
			continue
		}
		chosen, chosenName = container, name
		if name == key.DefaultContainer {
			break
		}
	}
	if chosen == nil {
		return "", false, "", fmt.Errorf("AmneziaVPN key has no WireGuard or AmneziaWG server")
	}
	// The client settings are JSON text in last_config; their "config" is the wg-quick text.
	var protocol struct {
		LastConfig string `json:"last_config"`
	}
	var client struct {
		Config string `json:"config"`
	}
	if json.Unmarshal(chosen[amneziaContainers[chosenName]], &protocol) != nil ||
		json.Unmarshal([]byte(protocol.LastConfig), &client) != nil || client.Config == "" {
		return "", false, "", fmt.Errorf("AmneziaVPN key has no client configuration")
	}
	config := client.Config
	// AmneziaVPN fills these in when it connects, from the DNS servers the key names.
	for placeholder, value := range map[string]string{"$PRIMARY_DNS": key.DNS1, "$SECONDARY_DNS": key.DNS2} {
		if !strings.Contains(config, placeholder) {
			continue
		}
		if value == "" || strings.ContainsAny(value, "\r\n") {
			return "", false, "", fmt.Errorf("AmneziaVPN key lacks the DNS servers its configuration names")
		}
		config = strings.ReplaceAll(config, placeholder, value)
	}
	return config, amneziaContainers[chosenName] == "awg", key.Description, nil
}

func importWireGuardLink(text string) (ClientProfile, error) {
	u, err := url.Parse(text)
	if err != nil {
		return ClientProfile{}, fmt.Errorf("invalid WireGuard link")
	}
	if u.Scheme == "vpn" {
		payload := strings.TrimPrefix(strings.SplitN(text, "#", 2)[0], "vpn://")
		decoded, err := decodeBase64Text(payload)
		if err != nil {
			return ClientProfile{}, fmt.Errorf("invalid AmneziaWG link encoding")
		}
		if !wireGuardText(decoded) {
			config, amnezia, name, err := amneziaKeyConfig([]byte(decoded))
			if err != nil {
				return ClientProfile{}, err
			}
			if u.Fragment != "" {
				name = u.Fragment
			}
			return importWireGuard(config, amnezia, name)
		}
		return importWireGuard(decoded, true, u.Fragment)
	}
	if u.Scheme != "wireguard" || u.User == nil {
		return ClientProfile{}, fmt.Errorf("invalid WireGuard link")
	}
	if _, password := u.User.Password(); password || u.Path != "" || strings.ContainsAny(u.User.Username(), "\r\n#;") {
		return ClientProfile{}, fmt.Errorf("invalid WireGuard credentials or path")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return ClientProfile{}, fmt.Errorf("invalid WireGuard query")
	}
	fields := map[string]string{"address": "Address", "dns": "DNS", "mtu": "MTU", "publickey": "PublicKey", "presharedkey": "PresharedKey", "persistentkeepalive": "PersistentKeepalive", "keepalive": "PersistentKeepalive", "allowedips": "AllowedIPs", "reserved": "Reserved"}
	iface, peer := "[Interface]\nPrivateKey="+u.User.Username()+"\n", "[Peer]\nEndpoint="+u.Host+"\n"
	for key, values := range q {
		name, ok := fields[strings.ToLower(key)]
		if !ok || len(values) != 1 || strings.ContainsAny(values[0], "\r\n") {
			return ClientProfile{}, fmt.Errorf("unsupported WireGuard query field")
		}
		if name == "Address" || name == "DNS" || name == "MTU" || name == "Reserved" {
			iface += name + "=" + values[0] + "\n"
		} else {
			peer += name + "=" + values[0] + "\n"
		}
	}
	return importWireGuard(iface+peer, false, u.Fragment)
}
