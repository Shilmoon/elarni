package share

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"strings"

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
	return json.RawMessage(bareIPv6Address(vBytes)), nil
}

// bareIPv6Address stores a server's IPv6 address as Xray JSON writes it: Xray's own text form of the
// address, which settings marshal through, puts it in brackets.
func bareIPv6Address(raw []byte) []byte {
	var settings struct {
		Address *string `json:"address"`
	}
	if !bytes.Contains(raw, []byte(`"address":"[`)) || json.Unmarshal(raw, &settings) != nil || settings.Address == nil {
		return raw
	}
	inner := strings.TrimSuffix(strings.TrimPrefix(*settings.Address, "["), "]")
	if address, err := netip.ParseAddr(inner); err != nil || !address.Is6() || "["+inner+"]" != *settings.Address {
		return raw
	}
	return bytes.Replace(raw, []byte(`"address":"`+*settings.Address+`"`), []byte(`"address":"`+inner+`"`), 1)
}
