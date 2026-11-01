package share

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/xtls/xray-core/infra/conf"
	"gopkg.in/yaml.v3"
)

func (proxy xrayShareLink) tuicOutbound() (*conf.OutboundDetourConfig, error) {
	u := proxy.link
	if u.Opaque != "" || u.Path != "" || u.User == nil {
		return nil, fmt.Errorf("invalid TUIC v5 URI")
	}
	if strings.Contains(u.Hostname(), ":") && !strings.HasPrefix(u.Host, "[") {
		return nil, fmt.Errorf("TUIC IPv6 URI requires brackets")
	}
	password, present := u.User.Password()
	if !present {
		return nil, fmt.Errorf("TUIC v5 requires UUID and password")
	}
	port, err := clientPort(u)
	if err != nil {
		return nil, fmt.Errorf("invalid TUIC server port")
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nil, fmt.Errorf("invalid TUIC URI parameters")
	}
	for key, values := range query {
		switch key {
		case "sni", "alpn", "congestion_control", "udp_relay_mode", "allow_insecure":
		default:
			return nil, fmt.Errorf("unsupported TUIC URI parameter")
		}
		if len(values) != 1 {
			return nil, fmt.Errorf("duplicate TUIC URI parameter")
		}
	}
	settings := &conf.TUICClientConfig{Address: parseAddress(u.Hostname()), Port: port, UUID: u.User.Username(), Password: &password,
		CongestionControl: query.Get("congestion_control"), UDPRelayMode: query.Get("udp_relay_mode")}
	tls := &conf.TLSConfig{ServerName: u.Hostname(), ALPN: new(conf.StringList([]string{"h3"}))}
	if sni, ok := query["sni"]; ok {
		if sni[0] == "" {
			return nil, fmt.Errorf("empty TUIC SNI")
		}
		tls.ServerName = sni[0]
	}
	if alpn, ok := query["alpn"]; ok {
		tls.ALPN = new(conf.StringList(strings.Split(alpn[0], ",")))
	}
	if insecure, ok := query["allow_insecure"]; ok {
		switch insecure[0] {
		case "0", "false":
		case "1", "true":
			tls.AllowInsecure = true
		default:
			return nil, fmt.Errorf("invalid TUIC verification flag")
		}
	}
	return tuicOutbound(settings, tls, u.Fragment)
}

func tuicOutbound(settings *conf.TUICClientConfig, tls *conf.TLSConfig, name string) (*conf.OutboundDetourConfig, error) {
	if _, err := settings.Build(); err != nil {
		return nil, err
	}
	raw, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound := &conf.OutboundDetourConfig{Protocol: "tuic", Settings: &raw, StreamSetting: &conf.StreamConfig{Security: "tls", TLSSettings: tls}}
	if _, err := outbound.Build(); err != nil {
		return nil, err
	}
	// TUIC profiles are runnable even through the legacy converter. Keep the
	// display name in the tag; SendThrough is a real socket bind address.
	outbound.Tag = name
	return outbound, nil
}

func (proxy ClashProxy) tuicOutbound() (*conf.OutboundDetourConfig, error) {
	password := proxy.Password
	settings := &conf.TUICClientConfig{Address: parseAddress(proxy.Server), Port: proxy.Port, UUID: proxy.Uuid, Password: &password,
		CongestionControl: proxy.CongestionController, UDPRelayMode: proxy.UDPRelayMode, ZeroRTTHandshake: proxy.ReduceRTT}
	if proxy.HeartbeatInterval != nil {
		ms := *proxy.HeartbeatInterval
		if ms <= 0 || ms > int64((time.Duration(1<<63-1))/time.Millisecond) {
			return nil, fmt.Errorf("invalid TUIC heartbeat interval")
		}
		settings.Heartbeat = (time.Duration(ms) * time.Millisecond).String()
	}
	sni := proxy.Sni
	if sni == "" {
		sni = proxy.Servername
	}
	if sni == "" {
		sni = proxy.Server
	}
	alpn := conf.StringList(proxy.Alpn)
	if proxy.Alpn == nil {
		alpn = conf.StringList{"h3"}
	}
	outbound, err := tuicOutbound(settings, &conf.TLSConfig{ServerName: sni, ALPN: &alpn, AllowInsecure: proxy.SkipCertVerify, PinnedPeerCertSha256: proxy.PinSHA256}, proxy.Name)
	if err != nil {
		return nil, err
	}
	if proxy.IPVersion != "" {
		strategies := map[string]string{"dual": "AsIs", "ipv4": "ForceIPv4", "ipv6": "ForceIPv6", "ipv4-prefer": "UseIPv4v6", "ipv6-prefer": "UseIPv6v4"}
		strategy, ok := strategies[proxy.IPVersion]
		if !ok {
			return nil, fmt.Errorf("invalid TUIC IP version")
		}
		outbound.TargetStrategy = strategy
	}
	return outbound, nil
}

// TUIC is strict even in the legacy converter: do not discard transport/security tuning.
func (proxy *ClashProxy) UnmarshalYAML(node *yaml.Node) error {
	type plain ClashProxy
	if err := node.Decode((*plain)(proxy)); err != nil {
		return err
	}
	if proxy.Type != "tuic" {
		return nil
	}
	var fields map[string]any
	if err := node.Decode(&fields); err != nil {
		return err
	}
	allowed := map[string]bool{"name": true, "type": true, "server": true, "port": true, "uuid": true, "password": true, "sni": true, "servername": true, "alpn": true, "skip-cert-verify": true, "congestion-controller": true, "udp-relay-mode": true, "reduce-rtt": true, "heartbeat-interval": true, "ip-version": true, "pin-sha256": true, "udp": true, "tls": true}
	for key := range fields {
		if !allowed[key] {
			return fmt.Errorf("unsupported TUIC Clash field")
		}
	}
	for _, key := range []string{"uuid", "password"} {
		if _, ok := fields[key].(string); !ok {
			return fmt.Errorf("TUIC v5 requires text UUID and password")
		}
	}
	for _, key := range []string{"server", "sni", "servername", "congestion-controller", "udp-relay-mode", "name", "ip-version", "pin-sha256"} {
		if value, exists := fields[key]; exists {
			if _, ok := value.(string); !ok {
				return fmt.Errorf("invalid TUIC text field")
			}
		}
	}
	for _, key := range []string{"skip-cert-verify", "reduce-rtt", "tls", "udp"} {
		if value, exists := fields[key]; exists {
			flag, ok := value.(bool)
			if !ok || ((key == "tls" || key == "udp") && !flag) {
				return fmt.Errorf("unsupported TUIC boolean field")
			}
		}
	}
	if proxy.Sni != "" && proxy.Servername != "" && proxy.Sni != proxy.Servername {
		return fmt.Errorf("conflicting TUIC TLS names")
	}
	if value, exists := fields["heartbeat-interval"]; exists {
		if _, ok := value.(int); !ok {
			if _, ok := value.(int64); !ok {
				return fmt.Errorf("TUIC heartbeat must be integer milliseconds")
			}
		}
	}
	return nil
}

func tuicLink(proxy conf.OutboundDetourConfig, link *url.URL) error {
	settings, err := decodeOutboundSettings[conf.TUICClientConfig](proxy)
	if err != nil {
		return err
	}
	if _, err := proxy.Build(); err != nil {
		return err
	}
	if settings.ZeroRTTHandshake || (settings.Heartbeat != "" && settings.Heartbeat != "10s") || proxy.SendThrough != nil || proxy.TargetStrategy != "" || proxy.StreamSetting.SocketSettings != nil {
		return fmt.Errorf("TUIC options require sharing the complete profile")
	}
	tls := proxy.StreamSetting.TLSSettings
	// Comparing supported fields against the complete TLS object avoids lossy export.
	representable := &conf.TLSConfig{ServerName: tls.ServerName, ALPN: tls.ALPN, AllowInsecure: tls.AllowInsecure}
	actual, _ := json.Marshal(tls)
	expected, _ := json.Marshal(representable)
	if string(actual) != string(expected) {
		return fmt.Errorf("TUIC TLS policy requires sharing the complete profile")
	}
	for _, alpn := range *tls.ALPN {
		if strings.Contains(alpn, ",") {
			return fmt.Errorf("TUIC ALPN requires full profile")
		}
	}
	var host string
	if settings.Address.Family().IsIP() {
		host = settings.Address.IP().String()
	} else {
		host = settings.Address.Domain()
	}
	link.Scheme, link.Host, link.User, link.Fragment = "tuic", net.JoinHostPort(host, strconv.Itoa(int(settings.Port))), url.UserPassword(settings.UUID, *settings.Password), getOutboundName(proxy)
	query := url.Values{}
	if tls.ServerName != "" {
		query.Set("sni", tls.ServerName)
	}
	query.Set("alpn", strings.Join(*tls.ALPN, ","))
	if tls.AllowInsecure {
		query.Set("allow_insecure", "1")
	}
	if settings.CongestionControl != "" {
		query.Set("congestion_control", settings.CongestionControl)
	}
	if settings.UDPRelayMode != "" {
		query.Set("udp_relay_mode", settings.UDPRelayMode)
	}
	link.RawQuery = query.Encode()
	return nil
}
