package share

import (
	"encoding/json"
	"fmt"

	"github.com/xtls/xray-core/infra/conf"
)

// buildHy2FinalMask builds Hysteria2 bandwidth / port hopping / salamander masks (shared by URI and Clash).
func buildHy2FinalMask(up, down, ports string, hopInterval conf.Int32Range, obfsType, obfsPassword string) (*conf.FinalMask, error) {
	var quicParams *conf.QuicParamsConfig
	if up != "" || down != "" {
		quicParams = &conf.QuicParamsConfig{Congestion: "brutal", BrutalUp: conf.Bandwidth(up), BrutalDown: conf.Bandwidth(down)}
	}

	var udpMasks []conf.Mask
	if obfsType != "" && (obfsType != "salamander" || obfsPassword == "") {
		return nil, fmt.Errorf("unsupported Hysteria2 obfuscation")
	}
	if obfsType == "salamander" {
		obfs := conf.Mask{Type: "salamander"}
		salamander := &conf.Salamander{Password: obfsPassword}
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
