package share

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/xtls/xray-core/infra/conf"
)

// buildHy2FinalMask builds Hysteria2 bandwidth / port hopping / salamander masks (shared by URI and Clash).
// Gecko is Xray's salamander with a packet size range, which 3x-ui and v2rayN write as minPacketSize and
// maxPacketSize; without them the mask cannot be built.
func buildHy2FinalMask(up, down, ports string, hopInterval conf.Int32Range, obfsType, obfsPassword, minPacketSize, maxPacketSize string) (*conf.FinalMask, error) {
	var quicParams *conf.QuicParamsConfig
	if up != "" || down != "" {
		quicParams = &conf.QuicParamsConfig{Congestion: "brutal", BrutalUp: conf.Bandwidth(up), BrutalDown: conf.Bandwidth(down)}
	}

	var udpMasks []conf.Mask
	if obfsType != "" && ((obfsType != "salamander" && obfsType != "gecko") || obfsPassword == "") {
		return nil, fmt.Errorf("unsupported Hysteria2 obfuscation")
	}
	if obfsType != "" {
		obfs := conf.Mask{Type: "salamander"}
		salamander := &conf.Salamander{Password: obfsPassword}
		if obfsType == "gecko" {
			size, err := geckoPacketSize(minPacketSize, maxPacketSize)
			if err != nil {
				return nil, err
			}
			salamander.PacketSize = size
		}
		salamanderRawMessage, err := convertJsonToRawMessage(salamander)
		if err != nil {
			return nil, err
		}
		obfs.Settings = &salamanderRawMessage
		udpMasks = append(udpMasks, obfs)
	}

	if ports != "" {
		var portList conf.PortList
		portListJSON, err := json.Marshal(ports)
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal(portListJSON, &portList); err != nil {
			return nil, err
		}
		// Hysteria hops to a new port from a new local socket. The hop mask dials, and
		// Xray applies masks last to first with only the first allowed to dial.
		hop, err := convertJsonToRawMessage(&conf.UDPHop{Mode: "intervalLocal,intervalRemote", Interval: hopInterval, RemotePorts: portList})
		if err != nil {
			return nil, err
		}
		udpMasks = append(udpMasks, conf.Mask{Type: "udphop", Settings: &hop})
	}

	if quicParams == nil && len(udpMasks) == 0 {
		return nil, nil
	}
	return &conf.FinalMask{QuicParams: quicParams, Udp: udpMasks}, nil
}

// geckoPacketSize reads gecko's packet sizes within the bounds Xray's salamander builds: 0 < min <= max <= 2048.
func geckoPacketSize(minPacketSize, maxPacketSize string) (conf.Int32Range, error) {
	low, lowErr := strconv.ParseUint(minPacketSize, 10, 16)
	high, highErr := strconv.ParseUint(maxPacketSize, 10, 16)
	if lowErr != nil || highErr != nil || low == 0 || low > high || high > 2048 {
		return conf.Int32Range{}, fmt.Errorf("unsupported Hysteria2 obfuscation")
	}
	return conf.Int32Range{Left: int32(low), Right: int32(high), From: int32(low), To: int32(high)}, nil
}
