package conf

import (
	"encoding/base64"
	"encoding/hex"
	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"net"
	"net/netip"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/task"
	"github.com/xtls/xray-core/proxy/wireguard"
	"google.golang.org/protobuf/proto"
)

type WireGuardPeerConfig struct {
	PublicKey      string   `json:"publicKey"`
	PreSharedKey   string   `json:"preSharedKey"`
	Endpoint       string   `json:"endpoint"`
	KeepAlive      uint32   `json:"keepAlive"`
	KeepAliveRange string   `json:"keepAliveRange,omitempty"`
	AllowedIPs     []string `json:"allowedIPs,omitempty"`

	Level uint32 `json:"level"`
	Email string `json:"email"`
}

func (c *WireGuardPeerConfig) Build() (*wireguard.PeerConfig, error) {
	var err error
	config := new(wireguard.PeerConfig)

	if c.PublicKey != "" {
		config.PublicKey, err = ParseWireGuardKey(c.PublicKey)
		if err != nil {
			return nil, err
		}
	}

	if c.PreSharedKey != "" {
		config.PreSharedKey, err = ParseWireGuardKey(c.PreSharedKey)
		if err != nil {
			return nil, err
		}
	}

	config.Endpoint = c.Endpoint
	if strings.ContainsAny(c.Endpoint, "\r\n") {
		return nil, errors.New("invalid peer endpoint")
	}
	if c.Endpoint != "" {
		host, port, err := net.SplitHostPort(c.Endpoint)
		p, portErr := strconv.ParseUint(port, 10, 16)
		if err != nil || portErr != nil || p == 0 || host == "" {
			return nil, errors.New("invalid peer endpoint")
		}
	}
	if c.KeepAlive != 0 {
		config.KeepAlive = strconv.FormatUint(uint64(c.KeepAlive), 10)
	}
	if c.KeepAliveRange != "" {
		var r awg.UintRange
		if err := r.FromString(c.KeepAliveRange); err != nil {
			return nil, errors.New("invalid keepalive range")
		}
		config.KeepAlive = c.KeepAliveRange
	}
	if c.AllowedIPs == nil {
		config.AllowedIps = []string{"0.0.0.0/0", "::0/0"}
	} else {
		config.AllowedIps = c.AllowedIPs
	}
	for _, prefix := range config.AllowedIps {
		if _, err := netip.ParsePrefix(prefix); err != nil {
			return nil, errors.New("invalid peer allowed IP")
		}
	}

	return config, nil
}

type WireGuardConfig struct {
	IsClient  bool              `json:"-"`
	IsAmnezia bool              `json:"-"`
	Amnezia   map[string]string `json:"amnezia,omitempty"`

	NoKernelTun    bool                   `json:"noKernelTun"`
	SecretKey      string                 `json:"secretKey"`
	Address        []string               `json:"address"`
	DNS            []string               `json:"dns,omitempty"`
	Peers          []*WireGuardPeerConfig `json:"peers"`
	MTU            int32                  `json:"mtu"`
	Reserved       []byte                 `json:"reserved"`
	DomainStrategy string                 `json:"domainStrategy"`
}

func (c *WireGuardConfig) Build() (proto.Message, error) {
	config := new(wireguard.DeviceConfig)
	if !c.IsAmnezia && len(c.Amnezia) > 0 {
		return nil, errors.New("Amnezia settings require amneziawg protocol")
	}
	if c.IsAmnezia {
		if len(c.Reserved) > 0 {
			return nil, errors.New("AmneziaWG does not use WireGuard reserved bytes")
		}
		if err := validateAmneziaSettings(c.Amnezia); err != nil {
			return nil, err
		}
		config.Amnezia, config.AmneziaSettings = true, c.Amnezia
	}

	var err error
	config.SecretKey, err = ParseWireGuardKey(c.SecretKey)
	if err != nil {
		return nil, errors.New("invalid WireGuard secret key: %w", err)
	}

	if c.Address == nil {
		// bogon ips
		config.Endpoint = []string{"10.0.0.1", "fd59:7153:2388:b5fd:0000:0000:0000:0001"}
	} else {
		config.Endpoint = c.Address
	}
	for _, address := range config.Endpoint {
		if _, err := netip.ParseAddr(address); err != nil {
			if _, err := netip.ParsePrefix(address); err != nil {
				return nil, errors.New("invalid WireGuard address")
			}
		}
	}

	if c.IsClient {
		config.Peers = make([]*wireguard.PeerConfig, len(c.Peers))
		for i, p := range c.Peers {
			if p == nil || p.PublicKey == "" || p.Endpoint == "" {
				return nil, errors.New("client peer requires key and endpoint")
			}
			if !c.IsAmnezia && p.KeepAliveRange != "" {
				return nil, errors.New("keepalive ranges require amneziawg")
			}
			msg, err := p.Build()
			if err != nil {
				return nil, err
			}
			config.Peers[i] = msg
		}
	} else {
		config.Users = make([]*protocol.User, len(c.Peers))
		processUser := func(idx int) error {
			p := c.Peers[idx]
			m, err := p.Build()
			if err != nil {
				return err
			}
			config.Users[idx] = &protocol.User{
				Email:   p.Email,
				Level:   p.Level,
				Account: serial.ToTypedMessage(m),
			}
			return nil
		}
		if err := task.ParallelForN(len(c.Peers), processUser); err != nil {
			return nil, err
		}
	}

	if c.MTU == 0 {
		config.Mtu = 1420
	} else {
		config.Mtu = c.MTU
	}
	if config.Mtu < 576 || config.Mtu > 65535 {
		return nil, errors.New("invalid WireGuard MTU")
	}

	if len(c.Reserved) != 0 && len(c.Reserved) != 3 {
		return nil, errors.New(`"reserved" should be empty or 3 bytes`)
	}
	config.Reserved = c.Reserved

	switch strings.ToLower(c.DomainStrategy) {
	case "forceip", "":
		config.DomainStrategy = wireguard.DeviceConfig_FORCE_IP
	case "forceipv4":
		config.DomainStrategy = wireguard.DeviceConfig_FORCE_IP4
	case "forceipv6":
		config.DomainStrategy = wireguard.DeviceConfig_FORCE_IP6
	case "forceipv4v6":
		config.DomainStrategy = wireguard.DeviceConfig_FORCE_IP46
	case "forceipv6v4":
		config.DomainStrategy = wireguard.DeviceConfig_FORCE_IP64
	default:
		return nil, errors.New("unsupported domain strategy: ", c.DomainStrategy)
	}

	config.IsClient = c.IsClient
	config.NoKernelTun = c.NoKernelTun
	for _, server := range c.DNS {
		if _, err := netip.ParseAddr(server); err != nil {
			return nil, errors.New("WireGuard DNS must be an IP address")
		}
	}
	config.DnsServers = c.DNS

	return config, nil
}

func ParseWireGuardKey(str string) (string, error) {
	var err error

	if str == "" {
		return "", errors.New("key must not be empty")
	}

	if len(str) == 64 {
		_, err = hex.DecodeString(str)
		if err == nil {
			return str, nil
		}
	}

	var dat []byte
	str = strings.TrimSuffix(str, "=")
	if strings.ContainsRune(str, '+') || strings.ContainsRune(str, '/') {
		dat, err = base64.RawStdEncoding.DecodeString(str)
	} else {
		dat, err = base64.RawURLEncoding.DecodeString(str)
	}
	if err == nil && len(dat) == 32 {
		return hex.EncodeToString(dat), nil
	}

	return "", errors.New("failed to deserialize key").Base(err)
}
