package share

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/infra/conf"
)

// FixWindowsReturn normalizes CRLF to LF (v2rayN exports on Windows).
func FixWindowsReturn(text string) string {
	return strings.ReplaceAll(text, "\r\n", "\n")
}

// decodeBase64Text decodes standard or URL-safe base64 (with optional missing padding).
func decodeBase64Text(text string) (string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", base64.CorruptInputError(0)
	}
	if b, err := base64.StdEncoding.DecodeString(text); err == nil {
		return string(b), nil
	}
	// URL-safe alphabet, with padding
	if b, err := base64.URLEncoding.DecodeString(text); err == nil {
		return string(b), nil
	}
	// URL-safe raw + manual padding (legacy v2rayN); the padding skips line
	// breaks, as the decoder does
	s := strings.NewReplacer("-", "+", "_", "/", "\r", "", "\n", "").Replace(text)
	if pad := len(s) % 4; pad != 0 {
		s += strings.Repeat("=", 4-pad)
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// https://github.com/XTLS/Xray-core/discussions/716

// ConvertShareLinksToXrayJson parses:
//   - a single Xray JSON object (starts with '{')
//   - plain v2rayN-style lines (vless/vmess/ss/socks/trojan/hy2…)
//   - one base64 blob that decodes to Xray JSON, share lines, or Clash YAML
//   - Clash / Clash.Meta YAML (proxies:)
func ConvertShareLinksToXrayJson(links string) (*conf.Config, error) {
	config, err := convertShareLinksToXrayJson(links, true)
	if err != nil {
		return nil, err
	}
	return filterBuildableOutbounds(config)
}

func convertShareLinksToXrayJson(links string, allowBase64 bool) (*conf.Config, error) {
	text := strings.TrimSpace(FixWindowsReturn(links))
	if text == "" {
		return nil, fmt.Errorf("unsupported share format")
	}
	if strings.HasPrefix(text, "{") {
		return parseXrayJSONConfig(text)
	}
	if hasShareSchemeLine(text) {
		return parsePlainShareLines(text)
	}
	if allowBase64 {
		decoded, err := decodeBase64Text(text)
		if err == nil {
			return convertShareLinksToXrayJson(decoded, false)
		}
	}
	if hasTopLevelClashProxiesKey(text) {
		return tryToParseClashYaml(text)
	}
	return nil, fmt.Errorf("unsupported share format")
}

func parseXrayJSONConfig(text string) (*conf.Config, error) {
	var xray *conf.Config
	if err := json.Unmarshal([]byte(text), &xray); err != nil {
		return nil, err
	}
	if len(xray.OutboundConfigs) == 0 {
		return nil, fmt.Errorf("no valid outbounds")
	}
	return xray, nil
}

var shareSchemes = []string{
	"vless://", "vmess://", "socks://", "socks5://", "http://", "https://", "ss://", "trojan://",
	"hysteria2://", "hy2://", "tuic://",
}

func hasShareSchemeLine(text string) bool {
	found := false
	forEachLine(text, func(raw string) bool {
		line := strings.TrimSpace(raw)
		for _, p := range shareSchemes {
			if strings.HasPrefix(line, p) {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

func hasTopLevelClashProxiesKey(text string) bool {
	found := false
	forEachLine(text, func(raw string) bool {
		line := strings.TrimRight(raw, " \t")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed == "---" || strings.HasPrefix(trimmed, "#") {
			return true
		}
		if strings.HasPrefix(line, "proxies:") {
			found = true
			return false
		}
		return true
	})
	return found
}

func forEachLine(text string, visit func(string) bool) {
	for {
		line, rest, ok := strings.Cut(text, "\n")
		if !visit(line) {
			return
		}
		if !ok {
			return
		}
		text = rest
	}
}

func parsePlainShareLines(text string) (*conf.Config, error) {
	outbounds := make([]conf.OutboundDetourConfig, 0)
	forEachLine(text, func(raw string) bool {
		line := strings.TrimSpace(raw)
		if line == "" {
			return true
		}
		u, err := parseClientLink(line)
		if err != nil {
			return true
		}
		sl := xrayShareLink{link: u, rawText: line}
		ob, err := sl.outbound()
		if err != nil {
			return true
		}
		outbounds = append(outbounds, *ob)
		return true
	})
	if len(outbounds) == 0 {
		return nil, fmt.Errorf("no valid outbound found")
	}
	return &conf.Config{OutboundConfigs: outbounds}, nil
}

type xrayShareLink struct {
	link    *url.URL
	rawText string
}

func (proxy xrayShareLink) outbound() (*conf.OutboundDetourConfig, error) {
	switch proxy.link.Scheme {
	case "ss":
		return proxy.shadowsocksOutbound()
	case "vmess":
		return proxy.vmessOutbound()
	case "vless":
		return proxy.vlessOutbound()
	case "socks", "socks5":
		return proxy.socksOutbound()
	case "http", "https":
		return proxy.httpOutbound()
	case "trojan":
		return proxy.trojanOutbound()
	case "hysteria2", "hy2":
		return proxy.hysteriaOutbound()
	case "tuic":
		return proxy.tuicOutbound()
	default:
		return nil, fmt.Errorf("unsupported client link scheme")
	}
}

func (proxy xrayShareLink) shadowsocksOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "shadowsocks"
	setOutboundName(outbound, proxy.link.Fragment)

	settings := &conf.ShadowsocksClientConfig{}
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	cipher, password, err := parseShadowsocksUserInfo(proxy.link.User)
	if err != nil {
		return nil, err
	}
	settings.Cipher = cipher
	settings.Password = password

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	if plugin := proxy.link.Query().Get("plugin"); plugin != "" {
		outbound.StreamSetting, err = shadowsocksPluginStream(plugin)
		return outbound, err
	}
	streamSettings, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

// shadowsocksPluginStream maps SIP002 "name;key=value;flag" options. Only
// v2ray-plugin's websocket mode exists in Xray, as on the Clash import path.
func shadowsocksPluginStream(plugin string) (*conf.StreamConfig, error) {
	options := strings.Split(plugin, ";")
	if options[0] != "v2ray-plugin" {
		return nil, fmt.Errorf("unsupported shadowsocks plugin")
	}
	ws := &conf.WebSocketConfig{}
	stream := &conf.StreamConfig{Network: new(conf.TransportProtocol("websocket")), Security: "none", WSSettings: ws}
	for _, option := range options[1:] {
		key, value, _ := strings.Cut(option, "=")
		switch key {
		case "mode":
			if value != "websocket" {
				return nil, fmt.Errorf("unsupported shadowsocks plugin mode")
			}
		case "host":
			ws.Host = value
		case "path":
			ws.Path = value
		case "tls":
			stream.Security = "tls"
		case "mux", "loglevel", "fastOpen":
			// Client-side tuning; v2ray-plugin servers accept plain websocket streams.
		default:
			return nil, fmt.Errorf("unsupported shadowsocks plugin option")
		}
	}
	if stream.Security == "tls" {
		stream.TLSSettings = &conf.TLSConfig{ServerName: ws.Host}
	}
	return stream, nil
}

func parseShadowsocksUserInfo(user *url.Userinfo) (string, string, error) {
	if user == nil {
		return "", "", fmt.Errorf("missing shadowsocks user info")
	}

	// SIP002 plain user info uses method:password. net/url decodes the
	// percent-encoded method and password independently.
	if password, ok := user.Password(); ok {
		cipher := user.Username()
		if cipher == "" {
			return "", "", fmt.Errorf("missing shadowsocks cipher")
		}
		return cipher, password, nil
	}

	// Username is the percent-decoded text; standard base64 escapes '/' and '='.
	decoded, err := decodeBase64Text(user.Username())
	if err != nil {
		return "", "", err
	}
	cipher, password, ok := strings.Cut(decoded, ":")
	if !ok || cipher == "" {
		return "", "", fmt.Errorf("unsupported shadowsocks user info")
	}
	return cipher, password, nil
}

func (proxy xrayShareLink) vmessOutbound() (*conf.OutboundDetourConfig, error) {
	text := strings.ReplaceAll(proxy.rawText, "vmess://", "")
	if base64Text, err := decodeBase64Text(text); err == nil {
		return parseVMessQrCode(base64Text)
	}

	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "vmess"
	setOutboundName(outbound, proxy.link.Fragment)
	query := proxy.link.Query()

	settings := conf.VMessOutboundConfig{}
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	id, err := url.PathUnescape(proxy.link.User.String())
	if err != nil {
		return nil, err
	}
	settings.ID = id
	if security := query.Get("encryption"); security != "" {
		settings.Security = security
	}

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

func (proxy xrayShareLink) vlessOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "vless"
	setOutboundName(outbound, proxy.link.Fragment)
	query := proxy.link.Query()

	settings := &conf.VLessOutboundConfig{}
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	id, err := url.PathUnescape(proxy.link.User.String())
	if err != nil {
		return nil, err
	}
	settings.Id = id
	if flow := query.Get("flow"); flow != "" {
		settings.Flow = flow
	}
	if enc := query.Get("encryption"); enc != "" {
		settings.Encryption = enc
	} else {
		settings.Encryption = "none"
	}

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

func (proxy xrayShareLink) socksOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "socks"
	setOutboundName(outbound, proxy.link.Fragment)

	settings := &conf.SocksClientConfig{}
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	settings.Username, settings.Password = proxyCredentials(proxy.link)

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

func (proxy xrayShareLink) trojanOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "trojan"
	setOutboundName(outbound, proxy.link.Fragment)

	settings := &conf.TrojanClientConfig{}
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	password, err := url.PathUnescape(proxy.link.User.String())
	if err != nil {
		return nil, err
	}
	settings.Password = password

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

func (proxy xrayShareLink) hysteriaOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "hysteria"
	setOutboundName(outbound, proxy.link.Fragment)

	settings := &conf.HysteriaClientConfig{}
	settings.Version = 2
	settings.Address = parseAddress(proxy.link.Hostname())
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	settings.Port = port

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings := &conf.StreamConfig{}
	streamSettings.Network = new(conf.TransportProtocol("hysteria"))

	hysteriaSettings := &conf.HysteriaConfig{}
	hysteriaSettings.Version = 2
	auth, err := url.PathUnescape(proxy.link.User.String())
	if err != nil {
		return nil, err
	}
	hysteriaSettings.Auth = auth
	streamSettings.HysteriaSettings = hysteriaSettings

	query := proxy.link.Query()
	// v2rayN names the hop range and interval mport and mportHopInt.
	for key, alias := range map[string]string{"ports": "mport", "hop-interval": "mportHopInt"} {
		if !query.Has(key) && query.Has(alias) {
			query.Set(key, query.Get(alias))
		}
	}
	var hopInterval conf.Int32Range
	if hopStr := query.Get("hop-interval"); hopStr != "" {
		interval, pErr := strconv.ParseInt(hopStr, 10, 32)
		if pErr != nil {
			return nil, pErr
		}
		i := int32(interval)
		hopInterval = conf.Int32Range{Left: i, Right: i, From: i, To: i}
	}
	finalMask, mErr := buildHy2FinalMask(
		query.Get("up"), query.Get("down"), query.Get("ports"),
		hopInterval, query.Get("obfs"), query.Get("obfs-password"),
	)
	if mErr != nil {
		return nil, mErr
	}
	streamSettings.FinalMask = finalMask
	if rawMask := query.Get("fm"); rawMask != "" {
		var explicit map[string]any
		if err := json.Unmarshal([]byte(rawMask), &explicit); err != nil || explicit == nil {
			return nil, fmt.Errorf("invalid Hysteria2 FinalMask")
		}
		if finalMask != nil {
			encoded, _ := json.Marshal(finalMask)
			var legacy map[string]any
			_ = json.Unmarshal(encoded, &legacy)
			if err := mergeMaskFields(explicit, legacy); err != nil {
				return nil, err
			}
		}
		encoded, _ := json.Marshal(explicit)
		if err := json.Unmarshal(encoded, &streamSettings.FinalMask); err != nil {
			return nil, fmt.Errorf("invalid Hysteria2 FinalMask")
		}
	}

	if err := proxy.parseSecurityFromURL(proxy.link, streamSettings); err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings
	return outbound, nil
}

func proxyCredentials(link *url.URL) (string, string) {
	if link.User == nil {
		return "", ""
	}
	if password, ok := link.User.Password(); ok {
		return link.User.Username(), password
	}
	if decoded, err := decodeBase64Text(link.User.Username()); err == nil {
		if username, password, ok := strings.Cut(decoded, ":"); ok {
			return username, password
		}
	}
	return link.User.Username(), ""
}

func (proxy xrayShareLink) httpOutbound() (*conf.OutboundDetourConfig, error) {
	// An HTTP proxy has no path, so a link with one is a web page, not a server.
	if proxy.link.Path != "" && proxy.link.Path != "/" {
		return nil, fmt.Errorf("web page link is not an HTTP proxy")
	}
	port, err := clientPort(proxy.link)
	if err != nil {
		return nil, err
	}
	username, password := proxyCredentials(proxy.link)
	settings, err := convertJsonToRawMessage(&conf.HTTPClientConfig{
		Address: parseAddress(proxy.link.Hostname()), Port: port, Username: username, Password: password,
	})
	if err != nil {
		return nil, err
	}
	stream, err := proxy.streamSettings(proxy.link)
	if err != nil {
		return nil, err
	}
	outbound := &conf.OutboundDetourConfig{Protocol: "http", Settings: &settings, StreamSetting: stream}
	setOutboundName(outbound, proxy.link.Fragment)
	return outbound, nil
}

// The Hysteria 2 URI may list hopping ports in the authority (host:443,5000-6000),
// which net/url refuses as a port; dial the first one and hop over the list.
func parseClientLink(line string) (*url.URL, error) {
	link, err := url.Parse(line)
	scheme, rest, _ := strings.Cut(line, "://")
	if err == nil || !(strings.EqualFold(scheme, "hy2") || strings.EqualFold(scheme, "hysteria2")) {
		return keepSemicolons(link), err
	}
	end := strings.IndexAny(rest, "/?#")
	if end == -1 {
		end = len(rest)
	}
	colon := strings.LastIndexByte(rest[:end], ':')
	if colon == -1 || !strings.ContainsAny(rest[colon+1:end], ",-") {
		return nil, err
	}
	ports := rest[colon+1 : end]
	first, _, _ := strings.Cut(strings.Split(ports, ",")[0], "-")
	if link, err = url.Parse(scheme + "://" + rest[:colon+1] + first + rest[end:]); err != nil {
		return nil, err
	}
	if query := keepSemicolons(link).Query(); query.Get("ports") == "" {
		query.Set("ports", ports)
		link.RawQuery = query.Encode()
	}
	return link, nil
}

// Many clients leave ';' bare in SIP002 plugin options and paths, and net/url drops
// every query parameter that holds one.
func keepSemicolons(link *url.URL) *url.URL {
	if link != nil {
		link.RawQuery = strings.ReplaceAll(link.RawQuery, ";", "%3B")
	}
	return link
}

func clientPort(link *url.URL) (uint16, error) {
	// An unbracketed IPv6 host would split at its last colon into another host and port.
	if link.Hostname() == "" || len(link.Hostname()) > 253 || (strings.Contains(link.Hostname(), ":") && !strings.HasPrefix(link.Host, "[")) {
		return 0, fmt.Errorf("invalid endpoint host")
	}
	text := link.Port()
	if text == "" {
		switch link.Scheme {
		case "trojan", "hy2", "hysteria2", "https":
			text = "443"
		case "http":
			text = "80"
		default:
			return 0, fmt.Errorf("missing endpoint port")
		}
	}
	port, err := strconv.ParseUint(text, 10, 16)
	if err != nil || port == 0 {
		return 0, fmt.Errorf("invalid endpoint port")
	}
	return uint16(port), nil
}

func mergeMaskFields(target, additions map[string]any) error {
	for key, value := range additions {
		if value == nil {
			continue
		}
		old, exists := target[key]
		if !exists || old == nil {
			target[key] = value
			continue
		}
		left, leftObject := old.(map[string]any)
		right, rightObject := value.(map[string]any)
		if leftObject && rightObject {
			if err := mergeMaskFields(left, right); err != nil {
				return err
			}
		} else {
			a, _ := json.Marshal(old)
			b, _ := json.Marshal(value)
			if string(a) != string(b) {
				return fmt.Errorf("conflicting Hysteria2 FinalMask settings")
			}
		}
	}
	return nil
}
