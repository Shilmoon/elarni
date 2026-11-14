package share

import (
	"encoding/json"
	"net/netip"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/infra/conf"
)

type XrayRawSettingsHeader struct {
	Type    string                        `json:"type,omitempty"`
	Request *XrayRawSettingsHeaderRequest `json:"request,omitempty"`
}

type XrayRawSettingsHeaderRequest struct {
	Path    []string                             `json:"path,omitempty"`
	Headers *XrayRawSettingsHeaderRequestHeaders `json:"headers,omitempty"`
}

type XrayRawSettingsHeaderRequestHeaders struct {
	Host []string `json:"Host,omitempty"`
}

type XrayFakeHeader struct {
	Type string `json:"type,omitempty"`
}

func setOutboundName(outbound *conf.OutboundDetourConfig, name string) {
	outbound.SendThrough = &name
}

func getOutboundName(outbound conf.OutboundDetourConfig) string {
	if outbound.SendThrough != nil {
		if len(*outbound.SendThrough) > 0 {
			return *outbound.SendThrough
		}
	}
	if len(outbound.Tag) > 0 {
		return outbound.Tag
	}
	if len(outbound.Protocol) > 0 {
		return outbound.Protocol
	}
	return ""
}

// shareName is the name a link gets. A parsed link carries its name in sendThrough, where a stored
// profile keeps what Xray JSON means by it, a bind address: that is not the server's name.
func shareName(outbound conf.OutboundDetourConfig) string {
	if outbound.SendThrough != nil && bindAddress(*outbound.SendThrough) {
		outbound.SendThrough = nil
	}
	return getOutboundName(outbound)
}

// bindAddress reports what Xray takes as sendThrough: an address, a prefix to pick one from, or "origin".
func bindAddress(text string) bool {
	if _, err := netip.ParseAddr(text); err == nil || text == "origin" {
		return true
	}
	_, err := netip.ParsePrefix(text)
	return err == nil
}

func parseAddress(addr string) *conf.Address {
	address := &conf.Address{}
	address.Address = net.ParseAddress(addr)
	return address
}

func convertJsonToRawMessage(v any) (json.RawMessage, error) {
	vBytes, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(vBytes), nil
}
