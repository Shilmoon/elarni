package share

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"reflect"
	"strings"
	"testing"

	"github.com/xtls/xray-core/infra/conf"
)

// Strict feed and credential ambiguity checks are separate from the traffic oracle.
func TestTUICStrictImportContract(t *testing.T) {
	const link = "tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=fixture.example&alpn=h3&congestion_control=cubic&udp_relay_mode=native&allow_insecure=0#TUIC%20%E2%9C%93"
	for _, input := range []string{link, base64.StdEncoding.EncodeToString([]byte(link))} {
		imported, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		if len(imported.Profiles) != 1 {
			t.Fatalf("profile count %d", len(imported.Profiles))
		}
		if !strings.Contains(string(imported.Profiles[0].Config), `"protocol":"tuic"`) {
			t.Fatal("TUIC profile missing")
		}
	}
	for _, input := range []string{
		strings.Replace(link, ":443?", ":65536?", 1),
		strings.Replace(link, "00000000-0000-4000-8000-000000000001", "invalid", 1),
		strings.Replace(link, "allow_insecure=0", "allow_insecure=0&allow_insecure=1", 1),
		strings.Replace(link, "allow_insecure=0", "allow_insecure=perhaps", 1),
		strings.Replace(link, "allow_insecure=0", "allow_insecure=0&insecure=1", 1),
		strings.Replace(link, "allow_insecure=0", "insecure=1&allowInsecure=0", 1),
		strings.Replace(link, "udp_relay_mode=native", "udp_over_stream=true", 1),
		strings.Replace(link, "congestion_control=cubic", "congestion_control=unknown", 1),
		strings.Replace(link, "?sni", "?token=v4&sni", 1),
		link + "\n" + strings.Replace(link, ":443?", ":0?", 1),
	} {
		if _, err := ImportClientProfiles(input); err == nil {
			t.Fatal("accepted invalid TUIC input")
		}
	}
}

// Panels write the verification flag under the aliases other link types accept.
func TestTUICInsecureAliases(t *testing.T) {
	const link = "tuic://00000000-0000-4000-8000-000000000001:secret@127.0.0.1:443?sni=127.0.0.1&"
	for query, want := range map[string]bool{
		"insecure=1":                     true,
		"allowInsecure=true":             true,
		"insecure=1&allow_insecure=1":    true,
		"insecure=0":                     false,
		"insecure=false&allowInsecure=0": false,
	} {
		imported, err := ImportClientProfiles(link + query)
		if err != nil {
			t.Fatalf("%s: %v", query, err)
		}
		var profile conf.Config
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		if got := profile.OutboundConfigs[0].StreamSetting.TLSSettings.AllowInsecure; got != want {
			t.Fatalf("%s: allowInsecure %v, want %v", query, got, want)
		}
	}
}

func TestTUICCredentialsClashExportAndBackup(t *testing.T) {
	const link = "tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=fixture.example&alpn=h3#TUIC%20%E2%9C%93"
	imported, err := ImportClientProfiles(link)
	if err != nil {
		t.Fatal(err)
	}
	var profile conf.Config
	json.Unmarshal(imported.Profiles[0].Config, &profile)
	settings, err := decodeOutboundSettings[conf.TUICClientConfig](profile.OutboundConfigs[0])
	if err != nil || *settings.Password != "p@ss:✓" || imported.Profiles[0].Name != "TUIC ✓" {
		t.Fatal("credentials or label changed", err)
	}
	exported, err := ConvertXrayJsonToShareLinks(imported.Profiles[0].Config)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(exported)
	if err != nil || u.Scheme != "tuic" || u.Query().Has("type") || u.Query().Has("security") {
		t.Fatal("exported unsupported URI dialect", err)
	}
	reimported, err := ImportClientProfiles(exported)
	if err != nil {
		t.Fatal(err)
	}
	var again conf.Config
	json.Unmarshal(reimported.Profiles[0].Config, &again)
	other, _ := decodeOutboundSettings[conf.TUICClientConfig](again.OutboundConfigs[0])
	if !reflect.DeepEqual(settings, other) {
		t.Fatal("TUIC export changed effective credentials/settings")
	}
	clash := "proxies:\n  - name: Fixture\n    type: tuic\n    server: ::1\n    port: 443\n    uuid: 00000000-0000-4000-8000-000000000001\n    password: 'p@ss:✓'\n    sni: fixture.example\n    alpn: [h3]\n    congestion-controller: bbr\n    udp-relay-mode: quic\n    reduce-rtt: true\n    heartbeat-interval: 1500\n"
	clashImport, err := ImportClientProfiles(clash)
	if err != nil {
		t.Fatal(err)
	}
	var cfg conf.Config
	json.Unmarshal(clashImport.Profiles[0].Config, &cfg)
	clashSettings, _ := decodeOutboundSettings[conf.TUICClientConfig](cfg.OutboundConfigs[0])
	if clashSettings.Heartbeat != "1.5s" || !clashSettings.ZeroRTTHandshake || clashSettings.UDPRelayMode != "quic" || clashSettings.CongestionControl != "bbr" {
		t.Fatal("lost TUIC Clash options")
	}
	full, err := ConvertXrayJsonToShareLinks(clashImport.Profiles[0].Config)
	if err != nil || !json.Valid([]byte(full)) {
		t.Fatal("advanced TUIC sharing must retain full profile", err)
	}
	for _, extra := range []string{"    token: v4\n", "    udp-over-stream: true\n", "    request-timeout: 1000\n", "    servername: conflicting.example\n", "    heartbeat-interval: 1.5\n", "    reduce-rtt: wrong\n", "    network: ws\n", "    alpn: []\n"} {
		// Replace an existing key when checking a distinct invalid type/value.
		input := clash + extra
		if strings.Contains(extra, "heartbeat-interval:") {
			input = strings.Replace(clash, "    heartbeat-interval: 1500\n", extra, 1)
		}
		if strings.Contains(extra, "reduce-rtt:") {
			input = strings.Replace(clash, "    reduce-rtt: true\n", extra, 1)
		}
		if strings.Contains(extra, "alpn:") {
			input = strings.Replace(clash, "    alpn: [h3]\n", extra, 1)
		}
		if _, err := ImportClientProfiles(input); err == nil {
			t.Fatal("accepted unsupported or ambiguous TUIC Clash options")
		}
	}
	var root map[string]any
	json.Unmarshal(clashImport.Profiles[0].Config, &root)
	backup := CatalogBackup{Version: 1, Subscriptions: []BackupSubscription{{ID: "source", Name: "Synthetic", Nodes: []BackupNode{{ID: "node", Name: "TUIC", Format: "xrayProfile", Config: root}}}}, SelectedNodeID: "node"}
	raw, _ := json.Marshal(backup)
	sealed, err := SealCatalogBackup(raw, "synthetic-backup-password")
	if err != nil || strings.Contains(sealed, "p@ss") {
		t.Fatal("backup encryption failed", err)
	}
	opened, err := OpenCatalogBackup(sealed, "synthetic-backup-password")
	if err != nil || !bytesEqualJSON(raw, opened) {
		t.Fatal("backup changed TUIC profile", err)
	}
	if _, err := ValidateCatalogBackup(opened); err != nil {
		t.Fatal(err)
	}
}

func bytesEqualJSON(a, b []byte) bool {
	var x, y any
	json.Unmarshal(a, &x)
	json.Unmarshal(b, &y)
	return reflect.DeepEqual(x, y)
}

func TestTUICLegacyClashPreservesSecurityAndIPPolicy(t *testing.T) {
	input := "proxies:\n- name: Fixture\n  type: tuic\n  server: fixture.example\n  port: 443\n  uuid: 00000000-0000-4000-8000-000000000001\n  password: ''\n  ip-version: ipv6\n  pin-sha256: '" + strings.Repeat("00", 32) + "'\n"
	cfg, err := ConvertShareLinksToXrayJson(input)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.OutboundConfigs) != 1 || cfg.OutboundConfigs[0].TargetStrategy != "ForceIPv6" || cfg.OutboundConfigs[0].StreamSetting.TLSSettings.PinnedPeerCertSha256 != strings.Repeat("00", 32) {
		t.Fatal("legacy TUIC conversion discarded IP or certificate policy")
	}
}

// Legacy conversion must produce a runnable profile: a display name is not a
// socket bind address. The public exporter must then retain its credentials.
func TestTUICLegacyURIShareRoundTrip(t *testing.T) {
	const input = "tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=fixture.example#TUIC%20%E2%9C%93"
	profile, err := ConvertShareLinksToXrayJson(input)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Build(); err != nil {
		t.Fatal("legacy TUIC profile cannot run", err)
	}
	raw, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	exported, err := ConvertXrayJsonToShareLinks(raw)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(exported)
	if err != nil || u.Scheme != "tuic" || u.Fragment != "TUIC ✓" {
		t.Fatal("legacy TUIC export lost its label")
	}
	password, present := u.User.Password()
	if !present || password != "p@ss:✓" {
		t.Fatal("legacy TUIC export changed credentials")
	}
	if _, err := ImportClientProfiles(exported); err != nil {
		t.Fatal(err)
	}
}
