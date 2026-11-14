package share

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/netip"
	"net/url"
	"reflect"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/infra/conf"
)

// Convert XrayJson to share links.
// VMess will generate VMessAEAD link.
func ConvertXrayJsonToShareLinks(xrayBytes []byte) (string, error) {
	var xray conf.Config
	if err := json.Unmarshal(xrayBytes, &xray); err != nil {
		return "", err
	}

	outbounds := xray.OutboundConfigs
	if len(outbounds) == 0 {
		return "", fmt.Errorf("no valid outbounds")
	}

	links := make([]string, 0, len(outbounds))
	for _, outbound := range outbounds {
		link, err := shareLink(outbound)
		if outbound.Protocol == "tuic" && (err != nil || len(outbounds) != 1 || xray.RouterConfig != nil || xray.DNSConfig != nil) {
			return string(xrayBytes), nil
		}
		if err != nil || link == nil {
			continue
		}
		text := link.String()
		if text != "" {
			links = append(links, text)
		}
	}
	if len(links) == 0 {
		return "", fmt.Errorf("no valid outbounds")
	}
	shareText := strings.Join(links, "\n")
	return shareText, nil
}

func shareLink(proxy conf.OutboundDetourConfig) (*url.URL, error) {
	shareUrl := &url.URL{}

	switch proxy.Protocol {
	case "tuic":
		if err := tuicLink(proxy, shareUrl); err != nil {
			return nil, err
		}
		return shareUrl, nil
	case "shadowsocks":
		err := shadowsocksLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	case "vmess":
		err := vmessLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	case "vless":
		err := vlessLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	case "socks":
		err := socksLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	case "trojan":
		err := trojanLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	case "hysteria":
		err := hysteriaLink(proxy, shareUrl)
		if err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("unsupported outbound protocol %q", proxy.Protocol)
	}
	streamSettingsQuery(proxy, shareUrl)

	return shareUrl, nil
}

func decodeOutboundSettings[T any](
	proxy conf.OutboundDetourConfig,
) (*T, error) {
	if proxy.Settings == nil {
		return nil, fmt.Errorf("missing %s outbound settings", proxy.Protocol)
	}
	raw := bytes.TrimSpace(*proxy.Settings)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return nil, fmt.Errorf("missing %s outbound settings", proxy.Protocol)
	}

	var settings T
	if err := json.Unmarshal(raw, &settings); err != nil {
		return nil, fmt.Errorf(
			"invalid %s outbound settings: %w",
			proxy.Protocol,
			err,
		)
	}
	return &settings, nil
}

// shareUser is the one user of a "vnext" or "servers" member, in the fields the links carry.
type shareUser struct {
	ID         string `json:"id"`
	Flow       string `json:"flow"`
	Encryption string `json:"encryption"`
	Security   string `json:"security"`
	Username   string `json:"user"`
	Password   string `json:"pass"`
}

// oneShareUser reads the user of a list that Xray allows one member: Xray JSON written by hand or by a
// panel names its server in "vnext" or "servers" instead of the flat fields.
func oneShareUser(protocol string, users []json.RawMessage) (*shareUser, error) {
	if len(users) != 1 {
		return nil, fmt.Errorf("%s outbound has %d users", protocol, len(users))
	}
	var user shareUser
	if err := json.Unmarshal(users[0], &user); err != nil {
		return nil, fmt.Errorf("invalid %s user: %w", protocol, err)
	}
	return &user, nil
}

// shareHost is the link's host and port; an outbound without a server has no link.
func shareHost(protocol string, address *conf.Address, port uint16) (string, error) {
	if address == nil || address.Address == nil {
		return "", fmt.Errorf("%s outbound has no server address", protocol)
	}
	return fmt.Sprintf("%s:%d", address, port), nil
}

func shadowsocksLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.ShadowsocksClientConfig](proxy)
	if err != nil {
		return err
	}
	if settings.Address == nil && len(settings.Servers) == 1 && settings.Servers[0] != nil {
		server := settings.Servers[0]
		settings.Address, settings.Port, settings.Cipher, settings.Password = server.Address, server.Port, server.Cipher, server.Password
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "ss"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}
	if isShadowsocksAEAD2022(settings.Cipher) {
		userInfo := escapeShadowsocksUserInfo(settings.Cipher) + ":" +
			escapeShadowsocksUserInfo(settings.Password)
		link.Opaque = "//" + userInfo + "@" + link.Host
		link.Host = ""
	} else {
		password := fmt.Sprintf("%s:%s", settings.Cipher, settings.Password)
		username := base64.StdEncoding.EncodeToString([]byte(password))
		link.User = url.User(username)
	}

	return nil
}

func isShadowsocksAEAD2022(cipher string) bool {
	switch strings.ToLower(cipher) {
	case "2022-blake3-aes-128-gcm",
		"2022-blake3-aes-256-gcm",
		"2022-blake3-chacha20-poly1305":
		return true
	default:
		return false
	}
}

func escapeShadowsocksUserInfo(value string) string {
	return strings.ReplaceAll(url.QueryEscape(value), "+", "%20")
}

func vmessLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.VMessOutboundConfig](proxy)
	if err != nil {
		return err
	}
	if settings.Address == nil && len(settings.Receivers) == 1 && settings.Receivers[0] != nil {
		server := settings.Receivers[0]
		user, err := oneShareUser(proxy.Protocol, server.Users)
		if err != nil {
			return err
		}
		settings.Address, settings.Port, settings.ID, settings.Security = server.Address, server.Port, user.ID, user.Security
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "vmess"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}
	link.User = url.User(settings.ID)
	if len(settings.Security) > 0 {
		link.RawQuery = addQuery(link.RawQuery, "encryption", settings.Security)
	}

	return nil
}

func vlessLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.VLessOutboundConfig](proxy)
	if err != nil {
		return err
	}
	if settings.Address == nil && len(settings.Vnext) == 1 && settings.Vnext[0] != nil {
		server := settings.Vnext[0]
		user, err := oneShareUser(proxy.Protocol, server.Users)
		if err != nil {
			return err
		}
		settings.Address, settings.Port = server.Address, server.Port
		settings.Id, settings.Flow, settings.Encryption = user.ID, user.Flow, user.Encryption
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "vless"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}
	link.User = url.User(settings.Id)
	if len(settings.Flow) > 0 {
		link.RawQuery = addQuery(link.RawQuery, "flow", settings.Flow)
	}
	if len(settings.Encryption) > 0 {
		link.RawQuery = addQuery(link.RawQuery, "encryption", settings.Encryption)
	}

	return nil
}

func socksLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.SocksClientConfig](proxy)
	if err != nil {
		return err
	}
	if settings.Address == nil && len(settings.Servers) == 1 && settings.Servers[0] != nil {
		server := settings.Servers[0]
		settings.Address, settings.Port = server.Address, server.Port
		// A SOCKS server may have no user at all.
		if len(server.Users) > 0 {
			user, err := oneShareUser(proxy.Protocol, server.Users)
			if err != nil {
				return err
			}
			settings.Username, settings.Password = user.Username, user.Password
		}
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "socks"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}
	if strings.Contains(settings.Username, ":") {
		// The base64 form is split at its first colon, which would cut this name.
		link.User = url.UserPassword(settings.Username, settings.Password)
	} else {
		password := fmt.Sprintf("%s:%s", settings.Username, settings.Password)
		username := base64.StdEncoding.EncodeToString([]byte(password))
		link.User = url.User(username)
	}

	return nil
}

func trojanLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.TrojanClientConfig](proxy)
	if err != nil {
		return err
	}
	if settings.Address == nil && len(settings.Servers) == 1 && settings.Servers[0] != nil {
		server := settings.Servers[0]
		settings.Address, settings.Port, settings.Password = server.Address, server.Port, server.Password
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "trojan"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}
	link.User = url.User(settings.Password)

	return nil
}

func hysteriaLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.HysteriaClientConfig](proxy)
	if err != nil {
		return err
	}

	link.Fragment = shareName(proxy)
	link.Scheme = "hysteria2"

	if link.Host, err = shareHost(proxy.Protocol, settings.Address, settings.Port); err != nil {
		return err
	}

	if proxy.StreamSetting != nil && proxy.StreamSetting.HysteriaSettings != nil {
		link.User = url.User(proxy.StreamSetting.HysteriaSettings.Auth)
	}

	return nil
}

func streamSettingsQuery(proxy conf.OutboundDetourConfig, link *url.URL) {
	streamSettings := proxy.StreamSetting
	if streamSettings == nil {
		if proxy.Protocol == "hysteria" {
			return
		}
		// Plain TCP is said as it is for a profile that has stream settings: a Trojan link without
		// "security" means TLS, and the link of a server must not change once it was imported.
		streamSettings = &conf.StreamConfig{}
	}
	query := link.RawQuery

	network := "raw"
	if streamSettings.Network != nil {
		network = shareNetwork(string(*streamSettings.Network))
	}

	if network == "hysteria" {
		// TLS params
		if streamSettings.TLSSettings != nil {
			sni := streamSettings.TLSSettings.ServerName
			if len(sni) > 0 {
				query = addQuery(query, "sni", sni)
			}
			fp := streamSettings.TLSSettings.Fingerprint
			if len(fp) > 0 {
				query = addQuery(query, "fp", fp)
			}
			alpn := streamSettings.TLSSettings.ALPN
			if alpn != nil && len(*alpn) > 0 {
				query = addQuery(query, "alpn", strings.Join(*alpn, ","))
			}
			ech := streamSettings.TLSSettings.ECHConfigList
			if len(ech) > 0 {
				query = addQuery(query, "ech", ech)
			}
			pcs := streamSettings.TLSSettings.PinnedPeerCertSha256
			if len(pcs) > 0 {
				query = addQuery(query, "pcs", pcs)
			}
			vcn := streamSettings.TLSSettings.VerifyPeerCertByName
			if len(vcn) > 0 {
				query = addQuery(query, "vcn", vcn)
			}
			if streamSettings.TLSSettings.AllowInsecure {
				query = addQuery(query, "insecure", "1")
			}
		}

		// QuicParams (bandwidth)
		if streamSettings.FinalMask != nil {
			for _, parameter := range hysteriaMaskQuery(streamSettings.FinalMask) {
				query = addQuery(query, parameter[0], parameter[1])
			}
		}
		link.RawQuery = query
		return
	}

	query = addQuery(query, "type", network)

	if len(streamSettings.Security) == 0 {
		streamSettings.Security = "none"
	}
	query = addQuery(query, "security", streamSettings.Security)

	switch network {
	case "raw", "tcp":
		// Xray reads either key and prefers the new one, as it does for XHTTP below.
		rawSettings := streamSettings.RAWSettings
		if rawSettings == nil {
			rawSettings = streamSettings.TCPSettings
		}
		if rawSettings == nil {
			break
		}

		headerConfig := rawSettings.HeaderConfig
		if headerConfig == nil {
			break
		}
		var header XrayRawSettingsHeader
		err := json.Unmarshal(headerConfig, &header)
		if err != nil {
			break
		}

		headerType := header.Type
		if len(headerType) > 0 {
			query = addQuery(query, "headerType", headerType)
			if header.Request == nil {
				break
			}
			path := header.Request.Path
			if len(path) > 0 {
				query = addQuery(query, "path", strings.Join(path, ","))
			}
			if header.Request.Headers == nil {
				break
			}
			host := header.Request.Headers.Host
			if len(host) > 0 {
				query = addQuery(query, "host", strings.Join(host, ","))
			}
		}
	case "kcp":
		if streamSettings.KCPSettings == nil {
			break
		}
		seed := streamSettings.KCPSettings.Seed
		if seed != nil && len(*seed) > 0 {
			query = addQuery(query, "seed", *seed)
		}

		headerConfig := streamSettings.KCPSettings.HeaderConfig
		if headerConfig == nil {
			break
		}
		var header XrayFakeHeader
		err := json.Unmarshal(headerConfig, &header)
		if err != nil {
			break
		}

		headerType := header.Type
		if len(headerType) > 0 {
			query = addQuery(query, "headerType", headerType)
		}
	case "ws":
		if streamSettings.WSSettings == nil {
			break
		}
		path := streamSettings.WSSettings.Path
		if len(path) > 0 {
			query = addQuery(query, "path", path)
		}
		host := streamSettings.WSSettings.Host
		if len(host) > 0 {
			query = addQuery(query, "host", host)
		}
	case "grpc":
		if streamSettings.GRPCSettings == nil {
			break
		}
		mode := streamSettings.GRPCSettings.MultiMode
		if mode {
			query = addQuery(query, "mode", "multi")
		} else {
			query = addQuery(query, "mode", "gun")
		}
		serviceName := streamSettings.GRPCSettings.ServiceName
		if len(serviceName) > 0 {
			query = addQuery(query, "serviceName", serviceName)
		}
		authority := streamSettings.GRPCSettings.Authority
		if len(authority) > 0 {
			query = addQuery(query, "authority", authority)
		}
	case "httpupgrade":
		if streamSettings.HTTPUPGRADESettings == nil {
			break
		}
		host := streamSettings.HTTPUPGRADESettings.Host
		if len(host) > 0 {
			query = addQuery(query, "host", host)
		}
		path := streamSettings.HTTPUPGRADESettings.Path
		if len(path) > 0 {
			query = addQuery(query, "path", path)
		}
	case "xhttp":
		xhttpSettings := streamSettings.XHTTPSettings
		if xhttpSettings == nil {
			xhttpSettings = streamSettings.SplitHTTPSettings
		}
		if xhttpSettings == nil {
			break
		}
		host := xhttpSettings.Host
		if len(host) > 0 {
			query = addQuery(query, "host", host)
		}
		path := xhttpSettings.Path
		if len(path) > 0 {
			query = addQuery(query, "path", path)
		}
		mode := xhttpSettings.Mode
		if len(mode) > 0 {
			query = addQuery(query, "mode", mode)
		}
		if extra := xhttpExtra(xhttpSettings); extra != "" {
			query = addQuery(query, "extra", extra)
		}
	}

	switch streamSettings.Security {
	case "tls":
		if streamSettings.TLSSettings == nil {
			// TLS with every setting at its default still has a name to say below.
			streamSettings.TLSSettings = &conf.TLSConfig{}
		}
		fp := streamSettings.TLSSettings.Fingerprint
		if len(fp) > 0 {
			query = addQuery(query, "fp", fp)
		}
		sni := streamSettings.TLSSettings.ServerName
		if sni == "" && network == "ws" && streamSettings.WSSettings != nil && streamSettings.WSSettings.Host != "" && !isIPHost(link.Hostname()) {
			// Xray sends the server's own name; a link without "sni" is read as the WebSocket host.
			sni = link.Hostname()
		}
		if len(sni) > 0 {
			query = addQuery(query, "sni", sni)
		}
		alpn := streamSettings.TLSSettings.ALPN
		if alpn != nil && len(*alpn) > 0 {
			query = addQuery(query, "alpn", strings.Join(*alpn, ","))
		}
		ech := streamSettings.TLSSettings.ECHConfigList
		if len(ech) > 0 {
			query = addQuery(query, "ech", ech)
		}
		pcs := streamSettings.TLSSettings.PinnedPeerCertSha256
		if len(pcs) > 0 {
			query = addQuery(query, "pcs", pcs)
		}
		vcn := streamSettings.TLSSettings.VerifyPeerCertByName
		if len(vcn) > 0 {
			query = addQuery(query, "vcn", vcn)
		}
		if streamSettings.TLSSettings.AllowInsecure {
			query = addQuery(query, "insecure", "1")
		}
	case "reality":
		if streamSettings.REALITYSettings == nil {
			break
		}
		fp := streamSettings.REALITYSettings.Fingerprint
		if len(fp) > 0 {
			query = addQuery(query, "fp", fp)
		}
		sni := streamSettings.REALITYSettings.ServerName
		if len(sni) > 0 {
			query = addQuery(query, "sni", sni)
		}
		// Xray reads the key from either name and prefers "password".
		pbk := streamSettings.REALITYSettings.Password
		if len(pbk) == 0 {
			pbk = streamSettings.REALITYSettings.PublicKey
		}
		if len(pbk) > 0 {
			query = addQuery(query, "pbk", pbk)
		}
		sid := streamSettings.REALITYSettings.ShortId
		if len(sid) > 0 {
			query = addQuery(query, "sid", sid)
		}
		pqv := streamSettings.REALITYSettings.Mldsa65Verify
		if len(pqv) > 0 {
			query = addQuery(query, "pqv", pqv)
		}
		spx := streamSettings.REALITYSettings.SpiderX
		if len(spx) > 0 {
			query = addQuery(query, "spx", spx)
		}
	}

	if streamSettings.FinalMask != nil {
		if mask := setJSON(streamSettings.FinalMask); mask != nil {
			query = addQuery(query, "fm", string(mask))
		}
	}

	link.RawQuery = query
}

// shareNetwork gives a transport the name share links use; Xray JSON also takes the long ones.
func shareNetwork(name string) string {
	switch name = strings.ToLower(name); name {
	case "websocket":
		return "ws"
	case "splithttp":
		return "xhttp"
	case "mkcp":
		return "kcp"
	default:
		return name
	}
}

// xhttpExtra is the link's "extra": the XHTTP settings a link has no parameter of its own for, read the
// way Xray reads them (a profile's own "extra" replaces the settings beside the path). It names only
// what the server sets, so the link stays short enough for a QR code.
func xhttpExtra(settings *conf.SplitHTTPConfig) string {
	effective := *settings
	if raw := bytes.TrimSpace(settings.Extra); len(raw) > 0 && !bytes.Equal(raw, []byte("null")) {
		effective = conf.SplitHTTPConfig{}
		if json.Unmarshal(raw, &effective) != nil {
			return ""
		}
	}
	effective.Host, effective.Path, effective.Mode, effective.Extra = "", "", "", nil
	return string(setJSON(&effective))
}

// setJSON is the settings behind a pointer as JSON that names only the fields that are set; nil when
// none is. Xray reads a null "extra" or "h2Params" as a value, so settings kept inside a profile must not
// carry the unset ones.
func setJSON(settings any) json.RawMessage {
	value := reflect.ValueOf(settings)
	if value.Kind() != reflect.Pointer || value.IsNil() {
		return nil
	}
	restoreNilRawMessages(value)
	set := setFields(value.Elem())
	if set == nil {
		return nil
	}
	// Through a map, so that settings a profile keeps as raw JSON come out in one key order.
	text, err := json.Marshal(set)
	var ordered any
	decoder := json.NewDecoder(bytes.NewReader(text))
	decoder.UseNumber()
	if err != nil || decoder.Decode(&ordered) != nil {
		return nil
	}
	if text, err = json.Marshal(ordered); err != nil {
		return nil
	}
	return text
}

// hysteriaMaskQuery writes a Hysteria2 mask as the link's own parameters when they say all of it, the
// form other clients read, and as "fm" alone otherwise: the importer refuses the two when they disagree.
func hysteriaMaskQuery(mask *conf.FinalMask) [][2]string {
	var up, down, ports, obfs, obfsPassword, minPacketSize, maxPacketSize string
	var interval conf.Int32Range
	if mask.QuicParams != nil {
		up, down = string(mask.QuicParams.BrutalUp), string(mask.QuicParams.BrutalDown)
	}
	for _, layer := range mask.Udp {
		if layer.Settings == nil {
			continue
		}
		switch strings.ToLower(layer.Type) {
		case "udphop":
			var hop conf.UDPHop
			if json.Unmarshal(*layer.Settings, &hop) == nil && len(hop.RemotePorts.Range) > 0 {
				ports, interval = hop.RemotePorts.String(), hop.Interval
			}
		case "salamander":
			var salamander conf.Salamander
			if json.Unmarshal(*layer.Settings, &salamander) == nil {
				obfs, obfsPassword = "salamander", salamander.Password
				// A packet size range makes it gecko, which links say as 3x-ui and v2rayN do.
				if salamander.PacketSize.To > 0 {
					obfs = "gecko"
					minPacketSize, maxPacketSize = strconv.Itoa(int(salamander.PacketSize.From)), strconv.Itoa(int(salamander.PacketSize.To))
				}
			}
		}
	}
	if own, err := buildHy2FinalMask(up, down, ports, interval, obfs, obfsPassword, minPacketSize, maxPacketSize); err != nil || !sameMask(own, mask) {
		if text := setJSON(mask); text != nil {
			return [][2]string{{"fm", string(text)}}
		}
		return nil
	}
	var query [][2]string
	add := func(key, value string) {
		if value != "" {
			query = append(query, [2]string{key, value})
		}
	}
	add("up", up)
	add("down", down)
	add("ports", ports)
	if interval.Left != 0 || interval.Right != 0 {
		add("hop-interval", interval.String())
	}
	add("obfs", obfs)
	if obfs != "" {
		query = append(query, [2]string{"obfs-password", obfsPassword})
	}
	add("minPacketSize", minPacketSize)
	add("maxPacketSize", maxPacketSize)
	return query
}

// sameMask compares two masks by the settings they set, however each spells them.
func sameMask(a, b *conf.FinalMask) bool {
	text := func(mask *conf.FinalMask) string {
		if mask == nil {
			return ""
		}
		spelled := *mask
		spelled.Udp = append([]conf.Mask(nil), mask.Udp...)
		for index, layer := range spelled.Udp {
			var settings any
			switch strings.ToLower(layer.Type) {
			case "udphop":
				settings = &conf.UDPHop{}
			case "salamander":
				settings = &conf.Salamander{}
			}
			if settings == nil || layer.Settings == nil || json.Unmarshal(*layer.Settings, settings) != nil {
				continue
			}
			raw := setJSON(settings)
			spelled.Udp[index].Type, spelled.Udp[index].Settings = strings.ToLower(layer.Type), &raw
		}
		return string(setJSON(&spelled))
	}
	return text(a) == text(b)
}

func isIPHost(host string) bool {
	_, err := netip.ParseAddr(host)
	return err == nil
}

var jsonMarshalerType = reflect.TypeFor[json.Marshaler]()

// setFields is an addressable value as JSON without the fields left at their zero value, which read
// back the same; nil when nothing is set. Ranges and addresses marshal through their pointer methods.
func setFields(value reflect.Value) any {
	if value.IsZero() {
		return nil
	}
	if value.Kind() == reflect.Pointer && !value.Type().Implements(jsonMarshalerType) {
		// An empty object or a false behind a pointer is still a setting.
		if value = value.Elem(); value.Kind() != reflect.Struct || reflect.PointerTo(value.Type()).Implements(jsonMarshalerType) {
			return value.Addr().Interface()
		}
		return structFields(value)
	}
	if value.Kind() == reflect.Struct && !value.Type().Implements(jsonMarshalerType) &&
		!reflect.PointerTo(value.Type()).Implements(jsonMarshalerType) {
		return structFields(value)
	}
	if value.Kind() != reflect.Pointer && value.CanAddr() {
		return value.Addr().Interface()
	}
	return value.Interface()
}

func structFields(value reflect.Value) map[string]any {
	fields := map[string]any{}
	for index := range value.NumField() {
		field := value.Type().Field(index)
		name, _, _ := strings.Cut(field.Tag.Get("json"), ",")
		if !field.IsExported() || name == "-" {
			continue
		}
		set := setFields(value.Field(index))
		if set == nil {
			continue
		}
		if embedded, ok := set.(map[string]any); ok && field.Anonymous && name == "" {
			for key, member := range embedded {
				fields[key] = member
			}
			continue
		}
		if name == "" {
			name = field.Name
		}
		fields[name] = set
	}
	return fields
}

func addQuery(rawQuery string, key, value string) string {
	v, err := url.ParseQuery(rawQuery)
	if err != nil {
		newPart := key + "=" + url.QueryEscape(value)
		if rawQuery == "" {
			return newPart
		}
		return rawQuery + "&" + newPart
	}
	v.Add(key, value)
	return v.Encode()
}
