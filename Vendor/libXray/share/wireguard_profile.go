package share

import (
	"encoding/json"
	"fmt"
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
		if !ok || value == "" || seen[key] || section == "" {
			return ClientProfile{}, fmt.Errorf("invalid WireGuard field on line %d", index+1)
		}
		seen[key] = true
		if section == "interface" {
			switch key {
			case "privatekey":
				settings.SecretKey = value
			case "address":
				settings.Address = commaValues(value)
			case "dns":
				dns = commaValues(value)
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
				peer.AllowedIPs = commaValues(value)
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
