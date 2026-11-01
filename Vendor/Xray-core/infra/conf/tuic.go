package conf

import (
	"bytes"
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/proxy/tuic"
	"google.golang.org/protobuf/proto"
)

type TUICClientConfig struct {
	Address           *Address `json:"address"`
	Port              uint16   `json:"port"`
	UUID              string   `json:"uuid"`
	Password          *string  `json:"password"`
	CongestionControl string   `json:"congestionControl"`
	UDPRelayMode      string   `json:"udpRelayMode"`
	Heartbeat         string   `json:"heartbeat"`
	ZeroRTTHandshake  bool     `json:"zeroRttHandshake"`
}

func (c *TUICClientConfig) UnmarshalJSON(data []byte) error {
	if err := uniqueTUICJSON(json.NewDecoder(bytes.NewReader(data))); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return errors.New("invalid TUIC settings")
	}
	for _, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return errors.New("TUIC settings require explicit typed values")
		}
	}
	type config TUICClientConfig
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode((*config)(c))
}

func (c *TUICClientConfig) Build() (proto.Message, error) {
	if c.Address == nil || c.Address.Address == nil || c.Address.String() == "" || c.Port == 0 {
		return nil, errors.New("TUIC requires a server address and port")
	}
	if c.Address.Family().IsDomain() && (len(c.Address.Domain()) > 253 || strings.ContainsAny(c.Address.Domain(), " /\\:@?#\t\r\n")) {
		return nil, errors.New("invalid TUIC server address")
	}
	if c.Password == nil {
		return nil, errors.New("TUIC v5 requires UUID and password")
	}
	id, err := uuid.Parse(c.UUID)
	if err != nil || len(c.UUID) != 36 {
		return nil, errors.New("invalid TUIC v5 UUID")
	}
	switch c.CongestionControl {
	case "", "cubic", "new_reno", "bbr":
	default:
		return nil, errors.New("unsupported TUIC congestion control")
	}
	switch c.UDPRelayMode {
	case "", "native", "quic":
	default:
		return nil, errors.New("unsupported TUIC UDP relay mode")
	}
	heartbeat := 10 * time.Second
	if c.Heartbeat != "" {
		heartbeat, err = time.ParseDuration(c.Heartbeat)
		if err != nil || heartbeat <= 0 {
			return nil, errors.New("invalid TUIC heartbeat duration")
		}
	}
	return &tuic.ClientConfig{Address: c.Address.Build(), Port: uint32(c.Port), Uuid: id[:], Password: *c.Password,
		CongestionControl: c.CongestionControl, UdpStream: c.UDPRelayMode == "quic", Heartbeat: int64(heartbeat), ZeroRttHandshake: c.ZeroRTTHandshake}, nil
}

// Scope strict field/duplicate checking to this new protocol, preserving other protocols' dialects.
func (c *OutboundDetourConfig) UnmarshalJSON(data []byte) error {
	type plain OutboundDetourConfig
	if err := json.Unmarshal(data, (*plain)(c)); err != nil {
		return err
	}
	if c.Protocol != "tuic" {
		return nil
	}
	if err := uniqueTUICJSON(json.NewDecoder(bytes.NewReader(data))); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode((*plain)(c)); err != nil {
		return errors.New("unsupported or invalid TUIC outbound field")
	}
	return nil
}

func uniqueTUICJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return errors.New("invalid TUIC JSON")
	}
	if delimiter, ok := token.(json.Delim); ok {
		if delimiter == '{' {
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return errors.New("invalid TUIC JSON")
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return errors.New("duplicate TUIC JSON field")
				}
				seen[name] = true
				if err := uniqueTUICJSON(decoder); err != nil {
					return err
				}
			}
		} else if delimiter == '[' {
			for decoder.More() {
				if err := uniqueTUICJSON(decoder); err != nil {
					return err
				}
			}
		} else {
			return errors.New("invalid TUIC JSON")
		}
		if _, err := decoder.Token(); err != nil {
			return errors.New("invalid TUIC JSON")
		}
	}
	return nil
}

func (c *Config) ValidateTUICChains() error {
	byTag := make(map[string]*OutboundDetourConfig)
	for i := range c.OutboundConfigs {
		byTag[c.OutboundConfigs[i].Tag] = &c.OutboundConfigs[i]
	}
	for i := range c.OutboundConfigs {
		ob := &c.OutboundConfigs[i]
		if ob.Protocol != "tuic" {
			continue
		}
		seen := map[string]bool{ob.Tag: true}
		for ob.StreamSetting != nil && ob.StreamSetting.SocketSettings != nil && ob.StreamSetting.SocketSettings.DialerProxy != "" {
			tag := ob.StreamSetting.SocketSettings.DialerProxy
			upstream := byTag[tag]
			if upstream == nil || seen[tag] {
				return errors.New("invalid TUIC UDP upstream chain")
			}
			seen[tag] = true
			switch upstream.Protocol {
			case "freedom", "direct", "socks", "shadowsocks", "vless", "vmess", "trojan", "hysteria", "tuic", "wireguard", "amneziawg":
			default:
				return errors.New("TUIC upstream must carry UDP datagrams")
			}
			ob = upstream
		}
	}
	return nil
}

func validateTUICTransport(c *OutboundDetourConfig) error {
	if c.StreamSetting == nil || c.StreamSetting.Security != "tls" {
		return errors.New("TUIC requires TLS")
	}
	s := c.StreamSetting
	for _, network := range []*TransportProtocol{s.Network, s.Method} {
		if network != nil && *network != "" && *network != "tcp" && *network != "raw" {
			return errors.New("TUIC does not support another transport")
		}
	}
	if s.Address != nil || s.Port != 0 || s.FinalMask != nil || s.REALITYSettings != nil || s.RAWSettings != nil || s.TCPSettings != nil || s.XHTTPSettings != nil || s.SplitHTTPSettings != nil || s.KCPSettings != nil || s.GRPCSettings != nil || s.WSSettings != nil || s.HTTPUPGRADESettings != nil || s.HysteriaSettings != nil {
		return errors.New("TUIC does not support transport overrides")
	}
	if c.ProxySettings != nil {
		return errors.New("TUIC upstream requires UDP-capable sockopt.dialerProxy; proxySettings is unsupported")
	}
	if c.MuxSettings != nil && c.MuxSettings.Enabled {
		return errors.New("TUIC uses native multiplexing; Xray mux is unsupported")
	}
	if s.TLSSettings == nil {
		s.TLSSettings = &TLSConfig{}
	}
	t := s.TLSSettings
	if t.Fingerprint != "" || t.MasterKeyLog != "" || t.ECHServerKeys != "" || t.ECHConfigList != "" || t.ECHSocketSettings != nil {
		return errors.New("unsupported TUIC TLS extension")
	}
	if t.MaxVersion != "" && t.MaxVersion != "1.3" {
		return errors.New("TUIC requires TLS 1.3")
	}
	if t.ALPN == nil {
		t.ALPN = new(StringList([]string{"h3"}))
	}
	if len(*t.ALPN) == 0 {
		return errors.New("TUIC requires nonempty ALPN")
	}
	for _, alpn := range *t.ALPN {
		if len(alpn) == 0 || len(alpn) > 255 {
			return errors.New("invalid TUIC ALPN")
		}
	}
	return nil
}
