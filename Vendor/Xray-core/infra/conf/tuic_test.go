package conf_test

import (
	"encoding/json"
	"testing"

	"github.com/xtls/xray-core/infra/conf"
)

// Security and unsupported-carrier failures cannot be proved by successful traffic.
func TestTUICOutboundContract(t *testing.T) {
	const settings = `"settings":{"address":"127.0.0.1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":""}`
	for _, fixture := range []struct {
		name, body string
		valid      bool
	}{
		{"defaults", settings + `,"streamSettings":{"security":"tls"}`, true},
		{"explicit QUIC modes", `"settings":{"address":"::1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture","udpRelayMode":"quic","congestionControl":"new_reno","heartbeat":"1500ms","zeroRttHandshake":true},"streamSettings":{"security":"tls","tlsSettings":{"alpn":["fixture"]}}`, true},
		{"TLS mandatory", settings, false},
		{"other security", settings + `,"streamSettings":{"security":"none"}`, false},
		{"other carrier", settings + `,"streamSettings":{"network":"ws","security":"tls"}`, false},
		{"mux", settings + `,"streamSettings":{"security":"tls"},"mux":{"enabled":true}`, false},
		{"legacy chain", settings + `,"streamSettings":{"security":"tls"},"proxySettings":{"tag":"upstream"}`, false},
		{"v4 token", `"settings":{"address":"127.0.0.1","port":443,"token":"fixture"},"streamSettings":{"security":"tls"}`, false},
		{"zero port", `"settings":{"address":"127.0.0.1","port":0,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture"},"streamSettings":{"security":"tls"}`, false},
		{"UUID", `"settings":{"address":"127.0.0.1","port":443,"uuid":"invalid","password":"fixture"},"streamSettings":{"security":"tls"}`, false},
		{"heartbeat overflow", `"settings":{"address":"127.0.0.1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture","heartbeat":"999999999999999999h"},"streamSettings":{"security":"tls"}`, false},
		{"heartbeat negative", `"settings":{"address":"127.0.0.1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture","heartbeat":"-1s"},"streamSettings":{"security":"tls"}`, false},
		{"unsupported relay", `"settings":{"address":"127.0.0.1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture","udpRelayMode":"udp_over_stream"},"streamSettings":{"security":"tls"}`, false},
		{"null heartbeat", `"settings":{"address":"127.0.0.1","port":443,"uuid":"00000000-0000-4000-8000-000000000001","password":"fixture","heartbeat":null},"streamSettings":{"security":"tls"}`, false},
		{"unknown TLS", settings + `,"streamSettings":{"security":"tls","tlsSettings":{"unknownPolicy":true}}`, false},
		{"duplicate verification flag", settings + `,"streamSettings":{"security":"tls","tlsSettings":{"allowInsecure":false,"allowInsecure":true}}`, false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var outbound conf.OutboundDetourConfig
			err := json.Unmarshal([]byte(`{"protocol":"tuic",`+fixture.body+`}`), &outbound)
			if err == nil {
				_, err = outbound.Build()
			}
			if (err == nil) != fixture.valid {
				t.Fatalf("valid=%t: %v", fixture.valid, err)
			}
		})
	}
}
