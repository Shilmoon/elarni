package share

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/xtls/xray-core/infra/conf"
)

// https://github.com/MetaCubeX/mihomo/blob/Alpha/docs/config.yaml

type ClashYaml struct {
	Proxies []ClashProxy `yaml:"proxies,omitempty"`
}

type ClashProxy struct {
	Name                 string `yaml:"name,omitempty"`
	Type                 string `yaml:"type,omitempty"`
	Server               string `yaml:"server,omitempty"`
	Port                 uint16 `yaml:"port,omitempty"`
	Uuid                 string `yaml:"uuid,omitempty"`
	Cipher               string `yaml:"cipher,omitempty"`
	Username             string `yaml:"username,omitempty"`
	Password             string `yaml:"password,omitempty"`
	Encryption           string `yaml:"encryption,omitempty"`
	CongestionController string `yaml:"congestion-controller,omitempty"`
	UDPRelayMode         string `yaml:"udp-relay-mode,omitempty"`
	ReduceRTT            bool   `yaml:"reduce-rtt,omitempty"`
	HeartbeatInterval    *int64 `yaml:"heartbeat-interval,omitempty"`
	IPVersion            string `yaml:"ip-version,omitempty"`
	PinSHA256            string `yaml:"pin-sha256,omitempty"`

	Ports        string `yaml:"ports,omitempty"`
	HopInterval  string `yaml:"hop-interval,omitempty"`
	Up           string `yaml:"up,omitempty"`
	Down         string `yaml:"down,omitempty"`
	Obfs         string `yaml:"obfs,omitempty"`
	ObfsPassword string `yaml:"obfs-password,omitempty"`

	Udp        bool `yaml:"udp,omitempty"`
	UdpOverTcp bool `yaml:"udp-over-tcp,omitempty"`

	Tls            bool     `yaml:"tls,omitempty"`
	SkipCertVerify bool     `yaml:"skip-cert-verify,omitempty"`
	Servername     string   `yaml:"servername,omitempty"`
	Sni            string   `yaml:"sni,omitempty"`
	Alpn           []string `yaml:"alpn,omitempty"`

	Fingerprint       string                 `yaml:"fingerprint,omitempty"`
	ClientFingerprint string                 `yaml:"client-fingerprint,omitempty"`
	Flow              string                 `yaml:"flow,omitempty"`
	RealityOpts       *ClashProxyRealityOpts `yaml:"reality-opts,omitempty"`

	Network    string                `yaml:"network,omitempty"`
	Plugin     string                `yaml:"plugin,omitempty"`
	PluginOpts *ClashProxyPluginOpts `yaml:"plugin-opts,omitempty"`
	EchOpts    *ClashProxyEchOpts    `yaml:"ech-opts,omitempty"`
	WsOpts     *ClashProxyWsOpts     `yaml:"ws-opts,omitempty"`
	GrpcOpts   *ClashProxyGrpcOpts   `yaml:"grpc-opts,omitempty"`
	XhttpOpts  *ClashProxyXhttpOpts  `yaml:"xhttp-opts,omitempty"`
}

type ClashProxyEchOpts struct {
	Enable bool   `yaml:"enable,omitempty"`
	Config string `yaml:"config,omitempty"`
}

type ClashProxyRealityOpts struct {
	PublicKey string `yaml:"public-key,omitempty"`
	ShortId   string `yaml:"short-id,omitempty"`
}

type ClashProxyPluginOpts struct {
	Mode           string             `yaml:"mode,omitempty"`
	Tls            bool               `yaml:"tls,omitempty"`
	Fingerprint    string             `yaml:"fingerprint,omitempty"`
	EchOpts        *ClashProxyEchOpts `yaml:"ech-opts,omitempty"`
	SkipCertVerify bool               `yaml:"skip-cert-verify,omitempty"`
	Host           string             `yaml:"host,omitempty"`
	Path           string             `yaml:"path,omitempty"`
	Mux            bool               `yaml:"mux,omitempty"`
}

type ClashProxyWsOpts struct {
	Path    string            `yaml:"path,omitempty"`
	Headers map[string]string `yaml:"headers,omitempty"`
}

type ClashProxyGrpcOpts struct {
	GrpcServiceName string `yaml:"grpc-service-name,omitempty"`
}

type ClashProxyXhttpOpts struct {
	Path               string                               `yaml:"path,omitempty"`
	Host               string                               `yaml:"host,omitempty"`
	Mode               string                               `yaml:"mode,omitempty"`
	Headers            map[string]string                    `yaml:"headers,omitempty"`
	NoGrpcHeader       bool                                 `yaml:"no-grpc-header,omitempty"`
	XPaddingBytes      string                               `yaml:"x-padding-bytes,omitempty"`
	ScMaxEachPostBytes string                               `yaml:"sc-max-each-post-bytes,omitempty"`
	ReuseSettings      *ClashProxyXhttpOptsXMUX             `yaml:"reuse-settings,omitempty"`
	DownloadSettings   *ClashProxyXhttpOptsDownloadSettings `yaml:"download-settings,omitempty"`
}

type ClashProxyXhttpOptsXMUX struct {
	MaxConnections   string `yaml:"max-connections,omitempty"`
	MaxConcurrency   string `yaml:"max-concurrency,omitempty"`
	CMaxReuseTimes   string `yaml:"c-max-reuse-times,omitempty"`
	HMaxRequestTimes string `yaml:"h-max-request-times,omitempty"`
	HMaxReusableSecs string `yaml:"h-max-reusable-secs,omitempty"`
}

type ClashProxyXhttpOptsDownloadSettings struct {
	Path               string                   `yaml:"path,omitempty"`
	Host               string                   `yaml:"host,omitempty"`
	Mode               string                   `yaml:"mode,omitempty"`
	Headers            map[string]string        `yaml:"headers,omitempty"`
	NoGrpcHeader       bool                     `yaml:"no-grpc-header,omitempty"`
	XPaddingBytes      string                   `yaml:"x-padding-bytes,omitempty"`
	ScMaxEachPostBytes string                   `yaml:"sc-max-each-post-bytes,omitempty"`
	ReuseSettings      *ClashProxyXhttpOptsXMUX `yaml:"reuse-settings,omitempty"`
	// proxy part
	Server            string                 `yaml:"server,omitempty"`
	Port              uint16                 `yaml:"port,omitempty"`
	Tls               bool                   `yaml:"tls,omitempty"`
	Alpn              []string               `yaml:"alpn,omitempty"`
	EchOpts           *ClashProxyEchOpts     `yaml:"ech-opts,omitempty"`
	RealityOpts       *ClashProxyRealityOpts `yaml:"reality-opts,omitempty"`
	SkipCertVerify    bool                   `yaml:"skip-cert-verify,omitempty"`
	Fingerprint       string                 `yaml:"fingerprint,omitempty"`
	Servername        string                 `yaml:"servername,omitempty"`
	ClientFingerprint string                 `yaml:"client-fingerprint,omitempty"`
}

func tryToParseClashYaml(text string) (*conf.Config, error) {
	var clash ClashYaml
	if err := yaml.Unmarshal([]byte(text), &clash); err != nil {
		return nil, err
	}
	config := clash.toXrayConfig()
	if len(config.OutboundConfigs) == 0 {
		return nil, fmt.Errorf("no valid outbound found")
	}
	return config, nil
}

func (clash ClashYaml) toXrayConfig() *conf.Config {
	outbounds := make([]conf.OutboundDetourConfig, 0, len(clash.Proxies))
	for _, proxy := range clash.Proxies {
		outbound, err := proxy.outbound()
		if err != nil {
			continue
		}
		outbounds = append(outbounds, *outbound)
	}
	return &conf.Config{OutboundConfigs: outbounds}
}

func (proxy ClashProxy) outbound() (*conf.OutboundDetourConfig, error) {
	switch proxy.Type {
	case "tuic":
		return proxy.tuicOutbound()
	case "ss":
		outbound, err := proxy.shadowsocksOutbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil

	case "vmess":
		outbound, err := proxy.vmessOutbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil

	case "vless":
		outbound, err := proxy.vlessOutbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil

	case "socks5":
		outbound, err := proxy.socksOutbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil
	case "trojan":
		outbound, err := proxy.trojanOutbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil
	case "hysteria2":
		outbound, err := proxy.hysteria2Outbound()
		if err != nil {
			return nil, err
		}
		return outbound, nil
	}
	return nil, fmt.Errorf("unsupported proxy type: %s", proxy.Type)
}

func (proxy ClashProxy) shadowsocksOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "shadowsocks"
	setOutboundName(outbound, proxy.Name)

	settings := conf.ShadowsocksClientConfig{}

	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settings.Cipher = proxy.Cipher
	settings.Password = proxy.Password

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	if len(proxy.Plugin) != 0 {
		if proxy.Plugin != "v2ray-plugin" {
			return nil, fmt.Errorf("unsupport ss plugin: obfs")
		}
		if proxy.PluginOpts == nil {
			return nil, fmt.Errorf("unsupport ss plugin-opts: nil")
		}
		if proxy.PluginOpts.Mode != "websocket" {
			return nil, fmt.Errorf("unsupport ss plugin-opts mode: %s", proxy.PluginOpts.Mode)
		}
		streamSetting := &conf.StreamConfig{}
		streamSetting.Network = new(conf.TransportProtocol("websocket"))

		wsSettings := &conf.WebSocketConfig{}
		if len(proxy.PluginOpts.Host) > 0 {
			wsSettings.Host = proxy.PluginOpts.Host
		}
		if len(proxy.PluginOpts.Path) > 0 {
			wsSettings.Path = proxy.PluginOpts.Path
		}
		streamSetting.WSSettings = wsSettings

		if proxy.PluginOpts.Tls {
			streamSetting.Security = "tls"
			tlsSettings := &conf.TLSConfig{ServerName: proxy.PluginOpts.Host, AllowInsecure: proxy.PluginOpts.SkipCertVerify}
			tlsSettings.PinnedPeerCertSha256 = proxy.PluginOpts.Fingerprint

			var err error
			if tlsSettings.ECHConfigList, err = echConfigList(proxy.PluginOpts.EchOpts); err != nil {
				return nil, err
			}

			streamSetting.TLSSettings = tlsSettings
		}

		outbound.StreamSetting = streamSetting
	}
	if proxy.Plugin == "" {
		stream, err := proxy.streamSettings(*outbound)
		if err != nil {
			return nil, err
		}
		outbound.StreamSetting = stream
	}
	return outbound, nil
}

func (proxy ClashProxy) vmessOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "vmess"
	setOutboundName(outbound, proxy.Name)

	settings := conf.VMessOutboundConfig{}

	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settings.ID = proxy.Uuid
	settings.Security = proxy.Cipher

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(*outbound)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings

	return outbound, nil
}

func (proxy ClashProxy) vlessOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "vless"
	setOutboundName(outbound, proxy.Name)

	settings := conf.VLessOutboundConfig{}

	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settings.Id = proxy.Uuid
	settings.Flow = proxy.Flow
	if len(proxy.Encryption) > 0 {
		settings.Encryption = proxy.Encryption
	} else {
		settings.Encryption = "none"
	}

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(*outbound)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings

	return outbound, nil
}

func (proxy ClashProxy) socksOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "socks"
	setOutboundName(outbound, proxy.Name)

	settings := conf.SocksClientConfig{}

	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settings.Username = proxy.Username
	settings.Password = proxy.Password

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(*outbound)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings

	return outbound, nil
}

func (proxy ClashProxy) trojanOutbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "trojan"
	setOutboundName(outbound, proxy.Name)

	settings := conf.TrojanClientConfig{}

	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settings.Password = proxy.Password

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(*outbound)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings

	return outbound, nil
}

func (proxy ClashProxy) hysteria2Outbound() (*conf.OutboundDetourConfig, error) {
	outbound := &conf.OutboundDetourConfig{}
	outbound.Protocol = "hysteria"
	setOutboundName(outbound, proxy.Name)

	settings := conf.HysteriaClientConfig{}

	settings.Version = 2
	settings.Address = parseAddress(proxy.Server)
	settings.Port = proxy.Port

	settingsRawMessage, err := convertJsonToRawMessage(settings)
	if err != nil {
		return nil, err
	}
	outbound.Settings = &settingsRawMessage

	streamSettings, err := proxy.streamSettings(*outbound)
	if err != nil {
		return nil, err
	}
	outbound.StreamSetting = streamSettings

	return outbound, nil
}

func (proxy ClashProxy) streamSettings(outbound conf.OutboundDetourConfig) (*conf.StreamConfig, error) {
	streamSettings := &conf.StreamConfig{}
	network := proxy.Network
	if len(proxy.Network) == 0 {
		network = "raw"
	}
	transportProtocol := conf.TransportProtocol(network)
	streamSettings.Network = &transportProtocol

	// fix hysteria network
	if proxy.Type == "hysteria2" {
		network = "hysteria"
		transportProtocol = "hysteria"
		streamSettings.Network = &transportProtocol
	}

	switch network {
	case "ws":
		if proxy.WsOpts != nil {
			wsSettings := &conf.WebSocketConfig{}
			for key, value := range proxy.WsOpts.Headers {
				if strings.EqualFold(key, "host") { // as Mihomo's http.Header
					wsSettings.Host = value
				}
			}
			wsSettings.Path = proxy.WsOpts.Path
			streamSettings.WSSettings = wsSettings
		}
	case "grpc":
		if proxy.GrpcOpts != nil {
			grpcSettings := &conf.GRPCConfig{}
			grpcSettings.ServiceName = proxy.GrpcOpts.GrpcServiceName
			streamSettings.GRPCSettings = grpcSettings
		}
	case "xhttp":
		if proxy.XhttpOpts != nil {
			xhttpSettings, err := parseXHTTPOpts(*proxy.XhttpOpts)
			if err != nil {
				return nil, err
			}
			streamSettings.XHTTPSettings = xhttpSettings
		}
	case "hysteria":
		hysteriaSettings := &conf.HysteriaConfig{}
		hysteriaSettings.Version = 2
		hysteriaSettings.Auth = proxy.Password
		streamSettings.HysteriaSettings = hysteriaSettings

		hopInterval, err := clashHopInterval(proxy.HopInterval)
		if err != nil {
			return nil, err
		}
		fm, err := buildHy2FinalMask(clashBandwidth(proxy.Up), clashBandwidth(proxy.Down), proxy.Ports, hopInterval, proxy.Obfs, proxy.ObfsPassword)
		if err != nil {
			return nil, err
		}
		streamSettings.FinalMask = fm
	}
	return streamSettings, proxy.parseSecurity(streamSettings, outbound)
}

var clashRate = regexp.MustCompile(`^(\d+)\s*([KMGT]?)([Bb])ps$`)

// clashBandwidth converts a Mihomo rate to Xray's bits per second. Mihomo reads a
// bare number as Mbps, B as bytes and b as bits with decimal prefixes, and
// ignores any other form.
func clashBandwidth(rate string) string {
	if n, err := strconv.Atoi(rate); err == nil {
		rate = strconv.Itoa(n) + " Mbps"
	}
	m := clashRate.FindStringSubmatch(rate)
	if m == nil {
		return ""
	}
	bits, _ := strconv.ParseUint(m[1], 10, 64)
	bits *= map[string]uint64{"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m[2]]
	if m[3] == "B" {
		bits *= 8
	}
	if bits == 0 {
		return ""
	}
	return strconv.FormatUint(bits, 10)
}

// clashHopInterval reads Mihomo's hop-interval, N or N-M seconds. Like Mihomo, it
// raises a start under 5 s to 5 and an end below the start to the start.
func clashHopInterval(value string) (conf.Int32Range, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return conf.Int32Range{}, nil
	}
	parts := strings.Split(value, "-")
	if len(parts) > 2 {
		return conf.Int32Range{}, fmt.Errorf("invalid hop-interval: %s", value)
	}
	bounds := make([]int32, len(parts))
	for i, part := range parts {
		n, err := strconv.ParseUint(strings.Trim(part, "[ ]"), 10, 31)
		if err != nil {
			return conf.Int32Range{}, fmt.Errorf("invalid hop-interval: %s", value)
		}
		bounds[i] = int32(n)
	}
	start, end := min(bounds[0], bounds[len(bounds)-1]), max(bounds[0], bounds[len(bounds)-1])
	if start == 0 {
		start = 30
	} else if start < 5 {
		start = 5
	}
	end = max(end, start)
	return conf.Int32Range{Left: start, Right: end, From: start, To: end}, nil
}

func (proxy ClashProxy) parseSecurity(streamSettings *conf.StreamConfig, outbound conf.OutboundDetourConfig) error {
	tlsSettings := &conf.TLSConfig{}
	realitySettings := &conf.REALITYConfig{}

	if proxy.Tls {
		streamSettings.Security = "tls"
	}

	if proxy.RealityOpts != nil {
		streamSettings.Security = "reality"
		realitySettings.PublicKey = proxy.RealityOpts.PublicKey
		realitySettings.ShortId = proxy.RealityOpts.ShortId
	}
	if len(proxy.Servername) > 0 {
		tlsSettings.ServerName = proxy.Servername
		realitySettings.ServerName = proxy.Servername
	}
	if len(proxy.Sni) > 0 {
		tlsSettings.ServerName = proxy.Sni
		realitySettings.ServerName = proxy.Sni
	}
	// Mihomo's vmess and vless send the ws Host as SNI when servername is unset; trojan does not.
	if tlsSettings.ServerName == "" && streamSettings.WSSettings != nil && (outbound.Protocol == "vmess" || outbound.Protocol == "vless") {
		tlsSettings.ServerName = streamSettings.WSSettings.Host
	}
	if len(proxy.Alpn) > 0 {
		tlsSettings.ALPN = new(conf.StringList(proxy.Alpn))
	}
	// Clash's fingerprint pins the server certificate; client-fingerprint names the uTLS hello.
	tlsSettings.PinnedPeerCertSha256 = proxy.Fingerprint
	if len(proxy.ClientFingerprint) > 0 {
		tlsSettings.Fingerprint = proxy.ClientFingerprint
		realitySettings.Fingerprint = proxy.ClientFingerprint
	}

	tlsSettings.AllowInsecure = proxy.SkipCertVerify

	if (outbound.Protocol == "trojan" || outbound.Protocol == "hysteria") && len(streamSettings.Security) == 0 {
		streamSettings.Security = "tls"
	}

	switch streamSettings.Security {
	case "tls":
		var err error
		if tlsSettings.ECHConfigList, err = echConfigList(proxy.EchOpts); err != nil {
			return err
		}
		streamSettings.TLSSettings = tlsSettings
	case "reality":
		streamSettings.REALITYSettings = realitySettings
	}
	return nil
}

// Mihomo fetches the ECH config over its own DNS when ech-opts names none; the core
// needs the list (or a DNS server), and dropping ECH would expose the real server name.
func echConfigList(opts *ClashProxyEchOpts) (string, error) {
	if opts == nil || !opts.Enable {
		return "", nil
	}
	if opts.Config == "" {
		return "", fmt.Errorf("ech-opts without an ECH config list is unsupported")
	}
	return opts.Config, nil
}

func parseXHTTPOpts(xhttpOpts ClashProxyXhttpOpts) (*conf.SplitHTTPConfig, error) {
	xhttpSettings := &conf.SplitHTTPConfig{}
	xhttpSettings.Path = xhttpOpts.Path
	xhttpSettings.Host = xhttpOpts.Host
	xhttpSettings.Mode = xhttpOpts.Mode

	extra := &conf.SplitHTTPConfig{}
	if len(xhttpOpts.Headers) > 0 {
		extra.Headers = xhttpOpts.Headers
	}
	extra.NoGRPCHeader = xhttpOpts.NoGrpcHeader
	if len(xhttpOpts.XPaddingBytes) > 0 {
		int32Range, err := parseInt32RangeString(xhttpOpts.XPaddingBytes)
		if err != nil {
			return nil, err
		}
		extra.XPaddingBytes = *int32Range
	}
	if len(xhttpOpts.ScMaxEachPostBytes) > 0 {
		int32Range, err := parseInt32RangeString(xhttpOpts.ScMaxEachPostBytes)
		if err != nil {
			return nil, err
		}
		extra.ScMaxEachPostBytes = *int32Range
	}
	if xhttpOpts.ReuseSettings != nil {
		xmuxSettings, err := parseXHTTPXMUX(xhttpOpts.ReuseSettings)
		if err != nil {
			return nil, err
		}
		extra.Xmux = *xmuxSettings
	}
	if xhttpOpts.DownloadSettings != nil {
		downloadSettings, err := parseXHTTPDownloadSettings(xhttpOpts.DownloadSettings)
		if err != nil {
			return nil, err
		}
		extra.DownloadSettings = downloadSettings
	}

	extraRawMessage, err := convertJsonToRawMessage(extra)
	if err != nil {
		return nil, err
	}
	xhttpSettings.Extra = extraRawMessage
	return xhttpSettings, nil
}

func parseInt32RangeString(s string) (*conf.Int32Range, error) {
	left, right, err := conf.ParseRangeString(s)
	if err != nil {
		return nil, err
	}
	return &conf.Int32Range{
		Left:  int32(left),
		Right: int32(right),
		From:  int32(left),
		To:    int32(right),
	}, nil
}

func parseXHTTPXMUX(reuseSettings *ClashProxyXhttpOptsXMUX) (*conf.XmuxConfig, error) {
	xmuxSettings := &conf.XmuxConfig{}
	if len(reuseSettings.MaxConnections) > 0 {
		int32Range, err := parseInt32RangeString(reuseSettings.MaxConnections)
		if err != nil {
			return nil, err
		}
		xmuxSettings.MaxConnections = *int32Range
	}
	if len(reuseSettings.MaxConcurrency) > 0 {
		int32Range, err := parseInt32RangeString(reuseSettings.MaxConcurrency)
		if err != nil {
			return nil, err
		}
		xmuxSettings.MaxConcurrency = *int32Range
	}
	if len(reuseSettings.CMaxReuseTimes) > 0 {
		int32Range, err := parseInt32RangeString(reuseSettings.CMaxReuseTimes)
		if err != nil {
			return nil, err
		}
		xmuxSettings.CMaxReuseTimes = *int32Range
	}
	if len(reuseSettings.HMaxRequestTimes) > 0 {
		int32Range, err := parseInt32RangeString(reuseSettings.HMaxRequestTimes)
		if err != nil {
			return nil, err
		}
		xmuxSettings.HMaxRequestTimes = *int32Range
	}
	if len(reuseSettings.HMaxReusableSecs) > 0 {
		int32Range, err := parseInt32RangeString(reuseSettings.HMaxReusableSecs)
		if err != nil {
			return nil, err
		}
		xmuxSettings.HMaxReusableSecs = *int32Range
	}
	return xmuxSettings, nil
}

func parseXHTTPDownloadSettings(downloadSettings *ClashProxyXhttpOptsDownloadSettings) (*conf.StreamConfig, error) {
	streamSettings := &conf.StreamConfig{}

	streamSettings.Address = parseAddress(downloadSettings.Server)
	streamSettings.Port = downloadSettings.Port

	streamSettings.Network = new(conf.TransportProtocol("xhttp"))

	xhttpSettings := &conf.SplitHTTPConfig{}
	xhttpSettings.Path = downloadSettings.Path
	xhttpSettings.Host = downloadSettings.Host
	xhttpSettings.Mode = downloadSettings.Mode

	if len(downloadSettings.Headers) > 0 {
		xhttpSettings.Headers = downloadSettings.Headers
	}
	xhttpSettings.NoGRPCHeader = downloadSettings.NoGrpcHeader
	if len(downloadSettings.XPaddingBytes) > 0 {
		int32Range, err := parseInt32RangeString(downloadSettings.XPaddingBytes)
		if err != nil {
			return nil, err
		}
		xhttpSettings.XPaddingBytes = *int32Range
	}
	if len(downloadSettings.ScMaxEachPostBytes) > 0 {
		int32Range, err := parseInt32RangeString(downloadSettings.ScMaxEachPostBytes)
		if err != nil {
			return nil, err
		}
		xhttpSettings.ScMaxEachPostBytes = *int32Range
	}
	if downloadSettings.ReuseSettings != nil {
		xmuxSettings, err := parseXHTTPXMUX(downloadSettings.ReuseSettings)
		if err != nil {
			return nil, err
		}
		xhttpSettings.Xmux = *xmuxSettings
	}
	streamSettings.XHTTPSettings = xhttpSettings

	return streamSettings, parseXHTTPDownloadSettingsSecurity(streamSettings, downloadSettings)
}

func parseXHTTPDownloadSettingsSecurity(streamSettings *conf.StreamConfig, proxy *ClashProxyXhttpOptsDownloadSettings) error {
	tlsSettings := &conf.TLSConfig{}
	realitySettings := &conf.REALITYConfig{}

	if proxy.Tls {
		streamSettings.Security = "tls"
	}

	if proxy.RealityOpts != nil {
		streamSettings.Security = "reality"
		realitySettings.PublicKey = proxy.RealityOpts.PublicKey
		realitySettings.ShortId = proxy.RealityOpts.ShortId
	}
	if len(proxy.Servername) > 0 {
		tlsSettings.ServerName = proxy.Servername
		realitySettings.ServerName = proxy.Servername
	}
	if len(proxy.Alpn) > 0 {
		tlsSettings.ALPN = new(conf.StringList(proxy.Alpn))
	}
	// Clash's fingerprint pins the server certificate; client-fingerprint names the uTLS hello.
	tlsSettings.PinnedPeerCertSha256 = proxy.Fingerprint
	if len(proxy.ClientFingerprint) > 0 {
		tlsSettings.Fingerprint = proxy.ClientFingerprint
		realitySettings.Fingerprint = proxy.ClientFingerprint
	}

	tlsSettings.AllowInsecure = proxy.SkipCertVerify

	switch streamSettings.Security {
	case "tls":
		var err error
		if tlsSettings.ECHConfigList, err = echConfigList(proxy.EchOpts); err != nil {
			return err
		}
		streamSettings.TLSSettings = tlsSettings
	case "reality":
		streamSettings.REALITYSettings = realitySettings
	}
	return nil
}
