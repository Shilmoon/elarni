package share

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/url"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// One unsupported line used to cost the user every server of the subscription: a member that
// cannot be imported is now skipped and reported, and the rest import.
func TestImportSkipsMembersItCannotImport(t *testing.T) {
	const id = "00000000-0000-4000-8000-000000000001"
	feed := strings.Join([]string{
		"vless://" + id + "@127.0.0.1:443?encryption=none#Kept",
		"vless://broken#Broken%20one",
		"unknown://broken",
		"VLESS://" + id + "@127.0.0.1:0?encryption=none#" + strings.Repeat("n", 129),
		"NOT A LINK",
		"wireguard://short@127.0.0.1:51820#wg",
		"x_y://broken#a%0Ab",
		"trojan://pw@127.0.0.1:443#Second",
	}, "\n")
	for _, input := range []string{feed, base64.StdEncoding.EncodeToString([]byte(feed))} {
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, profile := range result.Profiles {
			names = append(names, profile.Name)
		}
		if !slices.Equal(names, []string{"Kept", "Second"}) {
			t.Fatalf("imported %v", names)
		}
		want := []SkippedProfile{{Name: "Broken one", Kind: "vless"}, {Kind: "unknown"}, {Kind: "vless"}, {Kind: "link"},
			{Name: "wg", Kind: "wireguard"}, {Kind: "link"}}
		if !reflect.DeepEqual(result.Skipped, want) || result.SkippedCount != len(want) {
			t.Fatalf("skipped %+v (%d), want %+v", result.Skipped, result.SkippedCount, want)
		}
		encoded, err := json.Marshal(result)
		if err != nil || !bytes.Contains(encoded, []byte(`"skipped":[{"name":"Broken one","kind":"vless"},{"kind":"unknown"}`)) ||
			!bytes.Contains(encoded, []byte(`"skippedCount":6`)) {
			t.Fatalf("result JSON %s (%v)", encoded, err)
		}
	}
	// A feed with nothing to skip reports nothing.
	result, err := ImportClientProfiles("trojan://pw@127.0.0.1:443#One")
	if encoded, _ := json.Marshal(result); err != nil || bytes.Contains(encoded, []byte("skipped")) {
		t.Fatalf("clean feed reported skips: %s (%v)", encoded, err)
	}
}

// The report lists the first 32 skipped members and counts them all.
func TestImportReportsAtMost32SkippedMembers(t *testing.T) {
	lines := []string{"trojan://pw@127.0.0.1:443#Kept"}
	for i := range 40 {
		lines = append(lines, fmt.Sprintf("vless://broken#bad%d", i))
	}
	result, err := ImportClientProfiles(strings.Join(lines, "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Profiles) != 1 || len(result.Skipped) != 32 || result.SkippedCount != 40 || result.Skipped[31].Name != "bad31" {
		t.Fatalf("%d profiles, %d listed, %d counted", len(result.Profiles), len(result.Skipped), result.SkippedCount)
	}
}

// With nothing left to import, the first skipped member's error is the import's error, so a single
// bad link keeps the error it always had.
func TestImportWithNothingLeftKeepsTheFirstError(t *testing.T) {
	for input, want := range map[string]string{
		"vless://broken":                         "invalid or unsupported client link on line 1",
		"vless://%zz":                            "invalid client link on line 1",
		"# comment\nvless://broken\nunknown://x": "invalid or unsupported client link on line 2",
		`[null]`:                                 "profile 1 is not an object",
		`[null, {"outbounds":[{"protocol":"vless","settings":{"vnext":[null]}}]}]`: "profile 1 is not an object",
	} {
		if result, err := ImportClientProfiles(input); err == nil || err.Error() != want {
			t.Errorf("%q: %v (%+v), want %q", input, err, result, want)
		}
	}
	if _, err := ImportClientProfiles("wireguard://short@127.0.0.1:51820"); err == nil || !strings.HasPrefix(err.Error(), "invalid WireGuard or AmneziaWG link on line 1: ") {
		t.Errorf("WireGuard link: %v", err)
	}
	for _, input := range []string{"", "# only a comment", "[]"} {
		if _, err := ImportClientProfiles(input); err == nil {
			t.Errorf("%q imported", input)
		}
	}
}

func TestImportSkipsXrayArrayMembersItCannotImport(t *testing.T) {
	const valid = `{"remarks":"Kept","outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"}}]}`
	invalid := `{"remarks":"Broken","outbounds":[{"protocol":"vless","settings":{"vnext":[null]}}]}`
	unnamed := `{"outbounds":[{"protocol":"socks","settings":{"address":"127.0.0.1"}}]}`
	result, err := ImportClientProfiles("[" + strings.Join([]string{valid, "null", invalid, "5", unnamed, `{"name":"Named","protocol":"vless"}`}, ",") + "]")
	if err != nil {
		t.Fatal(err)
	}
	want := []SkippedProfile{{Kind: "xray"}, {Name: "Broken", Kind: "xray"}, {Kind: "xray"}, {Kind: "xray"}, {Name: "Named", Kind: "xray"}}
	if len(result.Profiles) != 1 || result.Profiles[0].Name != "Kept" || !reflect.DeepEqual(result.Skipped, want) || result.SkippedCount != 5 {
		t.Fatalf("profiles %+v, skipped %+v (%d)", result.Profiles, result.Skipped, result.SkippedCount)
	}
	// One object is one profile: it still fails as a whole.
	if _, err := ImportClientProfiles(invalid); err == nil {
		t.Fatal("invalid single profile imported")
	}
}

func TestClashImportSkipsProxiesItCannotConvert(t *testing.T) {
	const input = `proxies:
  - {name: one, type: socks5, server: 127.0.0.1, port: 1080}
  - {name: Bad, type: snell, server: 127.0.0.1, port: 1080}
  - {name: spaced, type: ss, server: edge example, port: 8388, cipher: chacha20-ietf-poly1305, password: fixture}
  - {name: weird, type: "Weird Type", server: 127.0.0.1, port: 1080}
  - {name: two, type: http, server: 127.0.0.1, port: 8080}
proxy-groups:
  - {name: PROXY, type: select, proxies: [Bad, one, OnlyBad, two], selected: Bad}
  - {name: OnlyBad, type: select, proxies: [Bad, spaced]}
  - {name: Outer, type: select, proxies: [OnlyBad, PROXY]}
rules:
  - DOMAIN-SUFFIX,example.org,DIRECT
  - MATCH,Outer
`
	result, err := ImportClientProfiles(input)
	if err != nil {
		t.Fatal(err)
	}
	want := []SkippedProfile{{Name: "Bad", Kind: "snell"}, {Name: "spaced", Kind: "ss"}, {Name: "weird", Kind: "clash"}}
	if len(result.Profiles) != 1 || !reflect.DeepEqual(result.Skipped, want) || result.SkippedCount != 3 {
		t.Fatalf("profiles %d, skipped %+v (%d)", len(result.Profiles), result.Skipped, result.SkippedCount)
	}
	var root struct {
		Outbounds []struct {
			Tag string `json:"tag"`
		} `json:"outbounds"`
		Groups []clashGroup `json:"elarniGroups"`
	}
	if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
		t.Fatal(err)
	}
	var tags []string
	for _, outbound := range root.Outbounds {
		tags = append(tags, outbound.Tag)
	}
	if !slices.Equal(tags, []string{"one", "two", "PROXY", "Outer", "DIRECT", "REJECT", "REJECT-DROP"}) {
		t.Fatalf("outbounds %v", tags)
	}
	// The dropped proxy leaves its groups, a group it leaves empty goes too, and the selection moves on.
	wantGroups := []clashGroup{{Name: "PROXY", Type: "select", Options: []string{"one", "two"}, Selected: "one"},
		{Name: "Outer", Type: "select", Options: []string{"PROXY"}, Selected: "PROXY"}}
	if !reflect.DeepEqual(root.Groups, wantGroups) {
		t.Fatalf("groups %+v", root.Groups)
	}
	// A rule naming what was dropped cannot be kept or rerouted: the file fails with the proxy's error.
	for _, target := range []string{"Bad", "OnlyBad"} {
		if _, err := ImportClientProfiles(strings.Replace(input, "MATCH,Outer", "MATCH,"+target, 1)); err == nil || err.Error() != "unsupported Clash proxy type snell" {
			t.Errorf("rule to %s: %v", target, err)
		}
	}
	// With no proxy left, the first one's error is the file's.
	if _, err := ImportClientProfiles("proxies:\n  - {name: Bad, type: snell, server: 127.0.0.1, port: 1080}\n  - {name: weird, type: x, server: 127.0.0.1, port: 1080}\n"); err == nil || err.Error() != "unsupported Clash proxy type snell" {
		t.Errorf("all proxies refused: %v", err)
	}
	// Structural errors still fail the file.
	for _, broken := range []string{input + "unknown-top-level: 1\n", strings.Replace(input, "type: select, proxies: [Bad, spaced]", "type: url-test, proxies: [Bad, spaced]", 1), input + "  - [not, a, rule\n"} {
		if _, err := ImportClientProfiles(broken); err == nil {
			t.Errorf("structurally broken file imported:\n%s", broken)
		}
	}
}

// Remnawave's default Mihomo template sets mode: global and writes packet-encoding: xudp on VLESS.
func TestClashGlobalModeAndPacketEncoding(t *testing.T) {
	const id = "00000000-0000-4000-8000-000000000001"
	input := `mixed-port: 7890
mode: global
proxies:
  - {name: a, type: vless, server: 127.0.0.1, port: 443, uuid: ` + id + `, packet-encoding: xudp}
  - {name: b, type: vless, server: 127.0.0.1, port: 444, uuid: ` + id + `, packet-encoding: ''}
proxy-groups:
  - {name: '→ Remnawave', type: select, proxies: [a, b]}
rules:
  - RULE-SET,unsupported,DIRECT
  - MATCH,→ Remnawave
`
	result, err := ImportClientProfiles(input)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
		t.Fatal(err)
	}
	if len(result.Skipped) != 0 || root["routing"] != nil || len(root["outbounds"].([]any)) != 6 {
		t.Fatalf("global mode: skipped %+v, config %s", result.Skipped, result.Profiles[0].Config)
	}
	if _, err := ImportClientProfiles(strings.Replace(input, "mode: global", "mode: direct", 1)); err == nil {
		t.Fatal("direct mode imported")
	}
	other := strings.Replace(input, "packet-encoding: ''", "packet-encoding: packetaddr", 1)
	result, err = ImportClientProfiles(other)
	if err != nil || len(result.Skipped) != 1 || result.Skipped[0] != (SkippedProfile{Name: "b", Kind: "vless"}) {
		t.Fatalf("another packet encoding: %+v, %v", result, err)
	}
	if _, err := ImportClientProfiles("proxies:\n  - {name: b, type: vless, server: 127.0.0.1, port: 444, uuid: " + id + ", packet-encoding: packetaddr}\n"); err == nil {
		t.Fatal("packetaddr imported")
	}
}

// amneziaKey writes a key as AmneziaVPN exports one: vpn:// and unpadded base64url of Qt's
// qCompress, a 4-byte big-endian length before a zlib stream.
func amneziaKey(t *testing.T, document any) string {
	t.Helper()
	text, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	var compressed bytes.Buffer
	_ = binary.Write(&compressed, binary.BigEndian, uint32(len(text)))
	writer, err := zlib.NewWriterLevel(&compressed, 8)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = writer.Write(text)
	_ = writer.Close()
	return "vpn://" + base64.RawURLEncoding.EncodeToString(compressed.Bytes())
}

func amneziaContainer(t *testing.T, container, protocol, config string) map[string]any {
	t.Helper()
	last, err := json.Marshal(map[string]any{"config": config, "hostName": "127.0.0.1", "port": 51820, "mtu": "1376"})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"container": container, protocol: map[string]any{"last_config": string(last), "port": "51820", "transport_proto": "udp"}}
}

func TestAmneziaVPNKeysImport(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	wireguard := "[Interface]\nAddress = 10.8.1.2/32\nDNS = $PRIMARY_DNS, $SECONDARY_DNS\nPrivateKey = " + key + "\n"
	awg := wireguard + "Jc = 4\nJmin = 40\nJmax = 80\nS1 = 16\nS2 = 17\nH1 = 100-110\nH2 = 200-210\nH3 = 300-310\nH4 = 400-410\n"
	peer := "\n[Peer]\nPublicKey = " + key + "\nPresharedKey = " + key + "\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 127.0.0.1:51820\nPersistentKeepalive = 25\n"
	document := func(defaultContainer string, containers ...map[string]any) map[string]any {
		return map[string]any{"containers": containers, "defaultContainer": defaultContainer, "description": "Fixture server",
			"dns1": "1.1.1.1", "dns2": "1.0.0.1", "hostName": "127.0.0.1"}
	}
	openvpn := map[string]any{"container": "amnezia-openvpn", "openvpn": map[string]any{"last_config": `{"config":"client\ndev tun\n"}`}}
	for name, test := range map[string]struct {
		link, protocol, name string
	}{
		"AmneziaWG":          {amneziaKey(t, document("amnezia-awg", amneziaContainer(t, "amnezia-awg", "awg", awg+peer))), "amneziawg", "Fixture server"},
		"AmneziaWG 2":        {amneziaKey(t, document("amnezia-awg2", amneziaContainer(t, "amnezia-awg2", "awg", awg+peer))), "amneziawg", "Fixture server"},
		"AWG without fields": {amneziaKey(t, document("amnezia-awg", amneziaContainer(t, "amnezia-awg", "awg", wireguard+peer))) + "#Named", "amneziawg", "Named"},
		"WireGuard":          {amneziaKey(t, document("amnezia-wireguard", openvpn, amneziaContainer(t, "amnezia-wireguard", "wireguard", wireguard+peer))), "wireguard", "Fixture server"},
		"no default":         {amneziaKey(t, document("", openvpn, amneziaContainer(t, "amnezia-awg", "awg", awg+peer))), "amneziawg", "Fixture server"},
	} {
		t.Run(name, func(t *testing.T) {
			result, err := ImportClientProfiles(test.link)
			if err != nil {
				t.Fatal(err)
			}
			var root struct {
				Outbounds []struct {
					Protocol string `json:"protocol"`
					Settings struct {
						Address []string `json:"address"`
					} `json:"settings"`
				} `json:"outbounds"`
				DNS struct {
					Servers []string `json:"servers"`
				} `json:"dns"`
			}
			if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
				t.Fatal(err)
			}
			if root.Outbounds[0].Protocol != test.protocol || !slices.Equal(root.DNS.Servers, []string{"1.1.1.1", "1.0.0.1"}) ||
				!slices.Equal(root.Outbounds[0].Settings.Address, []string{"10.8.1.2/32"}) || result.Profiles[0].Name != test.name {
				t.Fatalf("%s: %s", result.Profiles[0].Name, result.Profiles[0].Config)
			}
		})
	}
	for name, test := range map[string]struct {
		link, error string
	}{
		"OpenVPN default":  {amneziaKey(t, document("amnezia-openvpn", openvpn, amneziaContainer(t, "amnezia-awg", "awg", awg+peer))), "WireGuard"},
		"Xray only":        {amneziaKey(t, document("amnezia-xray", map[string]any{"container": "amnezia-xray", "xray": map[string]any{"last_config": "{}"}})), "WireGuard"},
		"no client config": {amneziaKey(t, document("amnezia-awg", map[string]any{"container": "amnezia-awg", "awg": map[string]any{"port": "51820"}})), "configuration"},
		"not JSON":         {"vpn://" + base64.RawURLEncoding.EncodeToString(append([]byte{0, 0, 0, 2}, zlibBytes(t, []byte("{]"))...)), "AmneziaVPN"},
		"over 1 MiB":       {"vpn://" + base64.RawURLEncoding.EncodeToString(append([]byte{0, 16, 0, 1}, zlibBytes(t, bytes.Repeat([]byte(" "), 1<<20+1))...)), "AmneziaVPN"},
	} {
		if _, err := ImportClientProfiles(test.link); err == nil || !strings.Contains(err.Error(), test.error) {
			t.Errorf("%s: %v, want an error naming %q", name, err, test.error)
		}
	}
}

func zlibBytes(t *testing.T, data []byte) []byte {
	t.Helper()
	var compressed bytes.Buffer
	writer := zlib.NewWriter(&compressed)
	_, _ = writer.Write(data)
	_ = writer.Close()
	return compressed.Bytes()
}

// Remnawave's subscription page writes happ://add/{{SUBSCRIPTION_LINK}}.
func TestHappAddLinksUnwrapLikeIncy(t *testing.T) {
	const target = "https://sub.example.com/feed/token?key=a%2Bb"
	for input, want := range map[string]ClientInput{
		"happ://add/" + target:                  {Text: target},
		"happ://add/" + target + "#Happ%20name": {Text: target, Name: "Happ name"},
		"happ://add/" + url.PathEscape(target):  {Text: target},
		"happ://routing/onadd/fixture":          {Text: "happ://routing/onadd/fixture"},
		"happ://crypt3/fixture":                 {Text: "happ://crypt3/fixture"},
	} {
		got, err := NormalizeClientInput(input)
		if err != nil || got != want {
			t.Errorf("%s: %+v, %v; want %+v", input, got, err, want)
		}
	}
}

// Marzban writes "allowInsecure": 1 in the VMess JSON; v2rayN writes "insecure": "1".
func TestVMessQRAllowInsecure(t *testing.T) {
	for fields, want := range map[string]bool{
		`"allowInsecure":1`: true, `"allowInsecure":"1"`: true, `"allowInsecure":true`: true, `"allowInsecure":"true"`: true,
		`"allowInsecure":0`: false, `"allowInsecure":"0"`: false, `"allowInsecure":false`: false, `"allowInsecure":null`: false,
		`"insecure":"1","allowInsecure":0`: true, `"insecure":"0","allowInsecure":1`: true, `"insecure":"1"`: true,
	} {
		qr := `{"v":"2","ps":"m","add":"127.0.0.1","port":"443","id":"00000000-0000-4000-8000-000000000001","net":"tcp","tls":"tls","sni":"example.com",` + fields + `}`
		result, err := ImportClientProfiles("vmess://" + base64.StdEncoding.EncodeToString([]byte(qr)))
		if err != nil {
			t.Fatalf("%s: %v", fields, err)
		}
		if got := strings.Contains(string(result.Profiles[0].Config), `"allowInsecure":true`); got != want {
			t.Errorf("%s: allowInsecure %v, want %v", fields, got, want)
		}
	}
}

// wg-quick adds up repeated Address and DNS lines and wg repeated AllowedIPs; old wgcf writes one
// Address line per family. ListenPort means nothing to a client.
func TestWireGuardRepeatedListsAccumulate(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	config := "[Interface]\nPrivateKey = " + key + "\nAddress = 172.16.0.2/32\nAddress = fd01::2/128\nDNS = 1.1.1.1\nDNS = 1.0.0.1, 2606:4700:4700::1111\nListenPort = 51820\n" +
		"[Peer]\nPublicKey = " + key + "\nAllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0\nEndpoint = 127.0.0.1:2408\n"
	result, err := ImportClientProfiles(config)
	if err != nil {
		t.Fatal(err)
	}
	var root struct {
		Outbounds []struct {
			Settings struct {
				Address []string `json:"address"`
				Peers   []struct {
					AllowedIPs []string `json:"allowedIPs"`
				} `json:"peers"`
			} `json:"settings"`
		} `json:"outbounds"`
		DNS struct {
			Servers []string `json:"servers"`
		} `json:"dns"`
	}
	if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
		t.Fatal(err)
	}
	settings := root.Outbounds[0].Settings
	if !slices.Equal(settings.Address, []string{"172.16.0.2/32", "fd01::2/128"}) || !slices.Equal(root.DNS.Servers, []string{"1.1.1.1", "1.0.0.1", "2606:4700:4700::1111"}) ||
		len(settings.Peers) != 1 || !slices.Equal(settings.Peers[0].AllowedIPs, []string{"0.0.0.0/0", "::/0"}) {
		t.Fatalf("lists lost: %s", result.Profiles[0].Config)
	}
	for _, duplicate := range []string{"PrivateKey = " + key, "MTU = 1280\nMTU = 1280", "ListenPort = 1", "Table = off"} {
		input := strings.Replace(config, "ListenPort = 51820", "ListenPort = 51820\n"+duplicate, 1)
		if _, err := ImportClientProfiles(input); err == nil {
			t.Errorf("accepted %q", duplicate)
		}
	}
	if _, err := ImportClientProfiles(strings.Replace(config, "Endpoint", "PublicKey = "+key+"\nEndpoint", 1)); err == nil {
		t.Error("accepted a repeated peer PublicKey")
	}
}

// The legacy Shadowsocks URI encodes the whole authority: ss://base64(method:password@host:port)#name.
func TestLegacyShadowsocksLinks(t *testing.T) {
	for link, want := range map[string][4]string{
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:p@ss:w/rd@127.0.0.1:8388")) + "#Legacy%20name": {"aes-256-gcm", "p@ss:w/rd", "127.0.0.1", "Legacy name"},
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:secret@legacy.example.com:443")): {"chacha20-ietf-poly1305", "secret", "legacy.example.com", ""},
		"ss://" + base64.RawStdEncoding.EncodeToString([]byte("aes-128-gcm:pw@[2001:db8::1]:8388")) + "#v6":            {"aes-128-gcm", "pw", "2001:db8::1", "v6"},
	} {
		result, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		var root struct {
			Outbounds []struct {
				Settings map[string]any `json:"settings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
			t.Fatal(err)
		}
		settings := root.Outbounds[0].Settings
		got := [4]string{fmt.Sprint(settings["method"]), fmt.Sprint(settings["password"]), fmt.Sprint(settings["address"]), result.Profiles[0].Name}
		if want[3] == "" {
			want[3] = "shadowsocks"
		}
		if got != want || settings["port"] == nil {
			t.Errorf("%s: %v, want %v", link, got, want)
		}
	}
	for _, link := range []string{
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:pw@2001:db8::1:8388")),
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:pw@127.0.0.1")),
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm@127.0.0.1:8388")),
		"ss://" + base64.StdEncoding.EncodeToString([]byte(":pw@127.0.0.1:8388")),
	} {
		if result, err := ImportClientProfiles(link); err == nil {
			t.Errorf("%s imported as %s", link, result.Profiles[0].Config)
		}
	}
}

// Xray writes an IPv6 address in brackets; profiles store the bare literal, as Xray JSON writes it.
func TestIPv6ServerAddressIsStoredWithoutBrackets(t *testing.T) {
	const id = "b831381d-6324-4d53-ad4f-8cda48b30811"
	qr := `{"v":"2","ps":"q","add":"2001:db8::10","port":"443","id":"` + id + `","net":"tcp"}`
	for _, link := range []string{
		"vless://" + id + "@[2001:db8::10]:443?encryption=none&security=tls&sni=v6.example.com&type=tcp#v6",
		"vmess://" + base64.StdEncoding.EncodeToString([]byte(qr)),
		"vmess://" + id + "@[2001:db8::10]:443#v6",
		"trojan://pw@[2001:db8::10]:443#v6",
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-256-gcm:pw")) + "@[2001:db8::10]:8388#v6",
		"socks://[2001:db8::10]:1080#v6",
		"http://[2001:db8::10]:8080#v6",
		"hy2://pw@[2001:db8::10]:443?sni=v6.example.com#v6",
		"tuic://" + id + ":pw@[2001:db8::10]:443?sni=v6.example.com#v6",
		"proxies:\n  - {name: v6, type: trojan, server: '2001:db8::10', port: 443, password: pw}\n",
	} {
		result, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		var root struct {
			Outbounds []struct {
				Settings struct {
					Address string `json:"address"`
				} `json:"settings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(result.Profiles[0].Config, &root); err != nil {
			t.Fatal(err)
		}
		if got := root.Outbounds[0].Settings.Address; got != "2001:db8::10" {
			t.Errorf("%s: address %q", link, got)
		}
		if strings.HasPrefix(link, "http://") {
			continue // Share writes no HTTP proxy links
		}
		links, err := ConvertXrayJsonToShareLinks(result.Profiles[0].Config)
		if err != nil || !strings.Contains(links, "[2001:db8::10]:") {
			t.Errorf("%s shares as %q (%v)", link, links, err)
		}
	}
}

// Mihomo's own resolver settings (fake-ip answers, bootstrap servers) describe Clash's DNS listener,
// which this app does not run; Remnawave's default template carries them.
func TestClashDNSIgnoresMihomoResolverSettings(t *testing.T) {
	input := `mode: rule
dns:
  enable: true
  use-hosts: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: [1.1.1.1, 8.8.8.8]
  nameserver: [1.1.1.1, 8.8.8.8]
  fake-ip-filter: ['*.lan']
proxies:
  - {name: a, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001}
`
	result, err := ImportClientProfiles(input)
	if err != nil || len(result.Profiles) != 1 || result.SkippedCount != 0 {
		t.Fatalf("%+v, %v", result, err)
	}
	if !strings.Contains(string(result.Profiles[0].Config), `"servers":["1.1.1.1","8.8.8.8"]`) {
		t.Fatalf("nameservers lost: %s", result.Profiles[0].Config)
	}
	if _, err := ImportClientProfiles(strings.Replace(input, "use-hosts: true", "fallback: [9.9.9.9]", 1)); err == nil {
		t.Fatal("an unknown DNS field imported")
	}
}
