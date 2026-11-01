package share

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/qrcode"
	"github.com/xtls/xray-core/app/proxyman"
	manager "github.com/xtls/xray-core/app/proxyman/outbound"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/transport/internet/finalmask/salamander"
	"github.com/xtls/xray-core/transport/internet/finalmask/udphop"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"image/png"
	"io"
	"net/url"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSubscriptionMigrationPreservesTokensAndRejectsUnsafeHints(t *testing.T) {
	const source = "https://old.example:8443/path/encoded%2Ftoken?key=a%2Bb"
	for _, test := range []struct {
		body, headers map[string]string
		want          string
		invalid       bool
	}{
		{body: map[string]string{"new-domain": "new.example"}, want: "https://new.example:8443/path/encoded%2Ftoken?key=a%2Bb"},
		{body: map[string]string{"new-domain": "old.example"}, want: ""},
		{body: map[string]string{"new-url": source}, want: ""},
		{body: map[string]string{"new-url": "https://body.example/feed"}, headers: map[string]string{"new-url": "https://header.example/new"}, want: "https://header.example/new"},
		{headers: map[string]string{"new-url": "http://new.example/feed"}, invalid: true},
		{headers: map[string]string{"new-url": "https://user:secret@new.example/feed"}, invalid: true},
		{headers: map[string]string{"new-domain": "new.example/path"}, invalid: true},
		{headers: map[string]string{"new-domain": "new.example:8443"}, invalid: true},
	} {
		got, err := SubscriptionMigrationURL(source, test.body, test.headers)
		if (err != nil) != test.invalid || got != test.want {
			t.Fatalf("migration result %q, error %v; expected %q invalid=%v", got, err, test.want, test.invalid)
		}
	}
	const profile = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?encryption=none#fixture"
	plain := "#new-domain next.example\n" + profile
	for _, input := range []string{plain, base64.StdEncoding.EncodeToString([]byte(plain))} {
		result, err := ImportClientProfiles(input)
		if err != nil || result.Migration["new-domain"] != "next.example" {
			t.Fatal("migration directive lost", err)
		}
	}
	// Happ writes body controls as "#name: value", Incy as "#name value".
	for _, body := range []string{"#new-url: https://next.example/feed\n#fallback-url: https://backup.example/feed\n" + profile,
		"#new-url https://next.example/feed\n#fallback-url https://backup.example/feed\n" + profile} {
		result, err := ImportClientProfiles(body)
		if err != nil || result.Migration["new-url"] != "https://next.example/feed" || result.Migration["fallback-url"] != "https://backup.example/feed" {
			t.Fatalf("body control lost from %q: %v %v", body, err, result)
		}
	}
}

// Happ's fallback-url: the provider's backup URL for when its main URL fails.
func TestSubscriptionFallbackURLIsValidatedLikeAMove(t *testing.T) {
	const source = "https://old.example/feed?token=a"
	for _, test := range []struct {
		body, headers map[string]string
		want          string
	}{
		{body: map[string]string{"fallback-url": "https://backup.example/feed?token=b"}, want: "https://backup.example/feed?token=b"},
		{body: map[string]string{"fallback-url": "https://body.example/feed"}, headers: map[string]string{"fallback-url": "https://header.example/feed"}, want: "https://header.example/feed"},
		{headers: map[string]string{"fallback-url": source}, want: ""},
		{headers: map[string]string{"fallback-url": "http://backup.example/feed"}, want: ""},
		{headers: map[string]string{"fallback-url": "https://user:secret@backup.example/feed"}, want: ""},
		{headers: map[string]string{"fallback-url": "not a url"}, want: ""},
		{want: ""},
	} {
		if got := SubscriptionFallbackURL(source, test.body, test.headers); got != test.want {
			t.Fatalf("fallback %q from %v %v, want %q", got, test.body, test.headers, test.want)
		}
	}
}

func TestClientSharingQRAndHiddenURLMetadata(t *testing.T) {
	const wire = "incy://add/https://sub.example.com/test-vector"
	encoded, err := ClientQR(wire)
	if err != nil {
		t.Fatal(err)
	}
	data, err := base64.StdEncoding.DecodeString(encoded["png"])
	if err != nil {
		t.Fatal(err)
	}
	picture, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	bitmap, err := gozxing.NewBinaryBitmapFromImage(picture)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := qrcode.NewQRCodeReader().DecodeWithoutHints(bitmap)
	if err != nil || decoded.GetText() != wire {
		t.Fatal("sharing QR lost the original link")
	}
	if large, err := ClientQR(strings.Repeat("x", 2801)); err != nil || len(large) != 0 {
		t.Fatal("large configuration must use Copy")
	}
	const profile = "socks://127.0.0.1:1080#Fixture"
	for _, body := range []string{"#hide-url: YES\n" + profile, base64.StdEncoding.EncodeToString([]byte("#hide-url: true\n" + profile))} {
		got, err := ImportClientProfiles(body)
		if err != nil || !got.HideURL {
			t.Fatal("hidden subscription URL marker lost")
		}
	}
}

func TestIncyInputsPreserveProfilesAndValidateCrypt1(t *testing.T) {
	const profile = "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?encryption=none&security=tls&sni=example.com#Fixture"
	for _, input := range []string{"incy://add/" + profile, "incy://import/" + base64.StdEncoding.EncodeToString([]byte(profile)), "incy://import/?data=" + url.QueryEscape(profile)} {
		got, err := ImportClientProfiles(input)
		if err != nil || len(got.Profiles) != 1 || got.Profiles[0].Name != "Fixture" {
			t.Fatal("documented INCY profile wrapper failed")
		}
	}
	// Published upstream cross-platform vector, independent of this wrapper.
	const wire = "incy://crypt1/AAECAwQFBgcICQoLNyIQL3rDwRZqnyoD8pGKSLXP6o8NdSXQVSSALNbbUyIr__tWGFUexdIfKvvmDnuDGbmBvuppfNef6aKNZUwOm4c-Sg"
	got, err := NormalizeClientInput(wire)
	if err != nil || got.Text != "https://sub.example.com/test-vector" || got.ShareLink != wire {
		t.Fatal("crypt1 vector or original sharing format was lost")
	}
	for _, input := range []string{wire[:len(wire)-8] + "AAAAAAAA", "incy://crypt1/invalid", strings.Repeat("incy://add/", 6) + profile} {
		if _, err := NormalizeClientInput(input); err == nil {
			t.Fatal("invalid wrapped link accepted")
		}
	}
	if got, err := ImportClientProfiles("incy://crypt1/unsupported-provider-directive\n" + profile); err != nil || len(got.Profiles) != 1 {
		t.Fatal("mixed-feed directive broke the existing import contract")
	}
	for _, command := range []string{"elarni://routing/add/synthetic", "elarni://routing/onadd/synthetic", "elarni://routing/off"} {
		directive := command
		for _, input := range []string{directive + "\n" + profile, profile + "\n" + directive} {
			got, err := ImportClientProfiles(input)
			if err != nil || len(got.Profiles) != 1 || len(got.Directives) != 1 || got.Directives[0] != directive {
				t.Fatalf("branded routing directive was not preserved for strict domain decoding: %v", err)
			}
		}
	}
}

func TestSubscriptionImportSeparatesFragmentNameFromDownloadURL(t *testing.T) {
	const target = "https://sub.example.com:2096/sub/encoded%2Ftoken?key=a%2Bb%23c"
	const labelled = target + "#VPN%20%D0%A2%D0%B5%D1%81%D1%82"
	for _, input := range []string{labelled, "incy://add/" + labelled, base64.StdEncoding.EncodeToString([]byte(labelled))} {
		got, err := NormalizeClientInput(input)
		if err != nil || got.Text != target || got.Name != "VPN Тест" {
			t.Fatalf("subscription name or request URL changed: %#v, %v", got, err)
		}
		if _, err := feedTarget(got.Text); err != nil {
			t.Fatal("normalized subscription still rejected by downloader", err)
		}
	}
	for _, input := range []string{
		"vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443#VPN",
		"https://user:secret@example.com:443/path#Proxy",
		"https://example.com:443#Proxy",
		"https://t.me/proxy?server=192.0.2.1&port=443&secret=fixture#Telegram",
	} {
		got, err := NormalizeClientInput(input)
		if err != nil || got.Text != input || got.Name != "" {
			t.Fatal("non-subscription profile fragment changed")
		}
	}
}

type countedResponse struct {
	io.Reader
	closes atomic.Int32
}

func (r *countedResponse) Close() error { r.closes.Add(1); return nil }

func TestXHTTPResponsePublicationAndCancellationCloseTheBodyOnce(t *testing.T) {
	for i := 0; i < 100; i++ {
		response := &countedResponse{Reader: strings.NewReader("fixture")}
		reader := &splithttp.WaitReadCloser{Wait: make(chan struct{})}
		done := make(chan struct{})
		go func() { defer close(done); _, _ = reader.Read(make([]byte, 1)) }()
		var work sync.WaitGroup
		work.Add(2)
		go func() { defer work.Done(); reader.Set(response) }()
		go func() { defer work.Done(); _ = reader.Close() }()
		work.Wait()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("cancelled XHTTP response kept its reader blocked")
		}
		_ = reader.Close()
		if response.closes.Load() != 1 {
			t.Fatal("XHTTP response body leaked or closed twice")
		}
	}
}

type selectionFixture struct {
	outbound.Handler
	tag string
}

func (f selectionFixture) Tag() string { return f.tag }

func TestProviderSelectorsCannotSelectAppHelpersOrCollideInCache(t *testing.T) {
	m, err := manager.New(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tag := range []string{"e", "elarni-direct", "one", "two", "one,elarni-exact:two"} {
		if err := m.AddHandler(context.Background(), selectionFixture{tag: tag}); err != nil {
			t.Fatal(err)
		}
	}
	for _, fixture := range []struct{ selectors, expected []string }{
		{[]string{"elarni-exact:e"}, []string{"e"}},
		{[]string{"e"}, []string{"e", "elarni-direct"}},
		{[]string{"elarni-exact:one", "elarni-exact:two"}, []string{"one", "two"}},
		{[]string{"elarni-exact:one,elarni-exact:two"}, []string{"one,elarni-exact:two"}},
	} {
		if actual := m.Select(fixture.selectors); !slices.Equal(actual, fixture.expected) {
			t.Fatalf("selector returned %v; want %v", actual, fixture.expected)
		}
	}
}

// Trojan share links default to TLS even when they have no query string.
// Omitting optional transport parameters must not remove authentication of the peer.
func TestTrojanDefaultsToTLSWithoutQuery(t *testing.T) {
	for _, query := range []string{"", "?type=tcp", "?security=tls", "?security=none"} {
		t.Run(query, func(t *testing.T) {
			config, err := ConvertShareLinksToXrayJson("trojan://fixture-password@127.0.0.1:443" + query + "#Fixture")
			if err != nil {
				t.Fatal(err)
			}
			stream := config.OutboundConfigs[0].StreamSetting
			if query == "?security=none" {
				if stream == nil || stream.Security != "none" || stream.TLSSettings != nil {
					t.Fatal("explicit Trojan security setting changed")
				}
				return
			}
			if stream == nil || stream.Security != "tls" || stream.TLSSettings == nil {
				t.Fatal("Trojan link lost its default TLS configuration")
			}
			if stream.TLSSettings.AllowInsecure {
				t.Fatal("default TLS configuration disabled peer verification")
			}
		})
	}
}

func TestClientJSONArraysRetainWholeProfiles(t *testing.T) {
	text := `[{"remarks":"Fixture","dns":{"servers":["192.0.2.53"]},"outbounds":[{"tag":"one","protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"}}],"routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"one"}]}}]`
	for _, input := range []string{text, base64.RawURLEncoding.EncodeToString([]byte(text))} {
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Profiles) != 1 || result.Profiles[0].Name != "Fixture" {
			t.Fatal("profile array was flattened or renamed")
		}
		var config map[string]json.RawMessage
		if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
			t.Fatal(err)
		}
		if string(config["dns"]) != `{"servers":["192.0.2.53"]}` || string(config["routing"]) != `{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"one"}]}` {
			t.Fatal("provider DNS or routing was discarded")
		}
	}
}

func TestProviderDNSThatAsksTheSystemResolverIsReported(t *testing.T) {
	// Xray answers "localhost", and a DNS block without servers, from the system resolver outside the tunnel.
	const outbounds = `"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"}}]`
	for dns, want := range map[string]bool{
		`"dns":{"servers":["localhost","1.1.1.1"]},`:                                 true,
		`"dns":{"servers":[{"address":"LocalHost","domains":["geosite:private"]}]},`: true,
		`"dns":{"hosts":{"example.com":"192.0.2.1"}},`:                               true,
		`"dns":{"servers":["1.1.1.1",{"address":"https://dns.example/dns-query"}]},`: false,
		`"dns":null,`: false,
		``:            false,
	} {
		result, err := ImportClientProfiles(`[{"remarks":"Fixture",` + dns + outbounds + `}]`)
		if err != nil {
			t.Fatalf("%s: %v", dns, err)
		}
		if result.SystemResolverDNS != want {
			t.Fatalf("%s: systemResolverDNS is %v", dns, result.SystemResolverDNS)
		}
	}
}

func TestStrictImportRejectsPartialFeeds(t *testing.T) {
	valid := "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?encryption=none"
	for _, input := range []string{valid + "\nvless://broken", valid + "\nunknown://broken",
		"proxies:\n  - {name: valid, type: socks5, server: 127.0.0.1, port: 1080}\n  - {name: unknown, type: unsupported, server: 127.0.0.1, port: 1080}",
		`[]`, `[null]`} {
		if _, err := ImportClientProfiles(input); err == nil {
			t.Fatal("partial or empty profile accepted")
		}
	}
}

// Xray 26.10.29 refuses outbound proxySettings, but saved and provider profiles still chain with
// it; the profile compiler turns it into sockopt.dialerProxy.
func TestProfilesChainedWithProxySettingsStillImport(t *testing.T) {
	for _, transportLayer := range []bool{false, true} {
		entry := map[string]any{"tag": "entry", "protocol": "vless", "settings": map[string]any{
			"address": "127.0.0.1", "port": 443, "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}}
		exit := map[string]any{"tag": "exit", "protocol": "vless", "settings": map[string]any{
			"address": "127.0.0.2", "port": 443, "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"},
			"proxySettings": map[string]any{"tag": "entry", "transportLayer": transportLayer}}
		raw, err := json.Marshal(map[string]any{"outbounds": []any{exit, entry}})
		if err != nil {
			t.Fatal(err)
		}
		imported, err := ImportClientProfiles(string(raw))
		if err != nil {
			t.Fatalf("transportLayer=%v: %v", transportLayer, err)
		}
		if !bytes.Contains(imported.Profiles[0].Config, []byte(`"proxySettings"`)) {
			t.Fatalf("transportLayer=%v: chain dropped: %s", transportLayer, imported.Profiles[0].Config)
		}
	}
}

func TestOutboundsWithMissingServersAreRejectedWithoutPanicking(t *testing.T) {
	for _, outbound := range []string{`{"protocol":"socks","settings":{"servers":[{"port":1080}]}}`,
		`{"protocol":"http","settings":{"servers":[null]}}`, `{"protocol":"http","settings":{"servers":[{"port":8080}]}}`,
		`{"protocol":"hysteria","settings":{"version":2,"port":443}}`,
		`{"protocol":"vless","settings":{"vnext":[null]}}`, `{"protocol":"dns","settings":{"rules":[null]}}`} {
		if _, err := ImportClientProfiles(outbound); err == nil {
			t.Fatalf("%s accepted", outbound)
		}
	}
}

func TestHTTPAndSOCKSCredentialsAndTLS(t *testing.T) {
	for _, input := range []string{"socks://user:p%2Ba%3Ass@127.0.0.1:1080", "socks://" + base64.RawURLEncoding.EncodeToString([]byte("user:p+a:ss")) + "@127.0.0.1:1080",
		"http://user:p%2Ba%3Ass@127.0.0.1:8080", "https://user:p%2Ba%3Ass@127.0.0.1:8443"} {
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		var config struct {
			Outbounds []struct {
				Settings struct {
					User string `json:"user"`
					Pass string `json:"pass"`
				} `json:"settings"`
				Stream struct {
					Security string `json:"security"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
			t.Fatal(err)
		}
		if config.Outbounds[0].Settings.User != "user" || config.Outbounds[0].Settings.Pass != "p+a:ss" {
			t.Fatal("proxy credentials changed")
		}
		if input[:5] == "https" && config.Outbounds[0].Stream.Security != "tls" {
			t.Fatal("HTTPS proxy lost TLS")
		}
	}
}

func TestPortOverflowDoesNotBecomeADifferentServer(t *testing.T) {
	for _, input := range []string{"trojan://secret@127.0.0.1:65536", "hy2://secret@127.0.0.1:65537", "http://127.0.0.1:0"} {
		if _, err := ImportClientProfiles(input); err == nil {
			t.Fatal("invalid server port was accepted")
		}
	}
	for _, port := range []any{-1, 0, 65536, 65537, 131515, "65536", "-1", 443.5} {
		qr, _ := json.Marshal(map[string]any{"add": "127.0.0.1", "port": port, "id": "00000000-0000-4000-8000-000000000001"})
		if _, err := ImportClientProfiles("vmess://" + base64.StdEncoding.EncodeToString(qr)); err == nil {
			t.Fatalf("invalid VMess QR port %v was accepted", port)
		}
	}
	for _, port := range []any{1, 65535, "443"} {
		qr, _ := json.Marshal(map[string]any{"add": "127.0.0.1", "port": port, "id": "00000000-0000-4000-8000-000000000001"})
		if _, err := ImportClientProfiles("vmess://" + base64.StdEncoding.EncodeToString(qr)); err != nil {
			t.Fatalf("valid VMess QR port %v rejected: %v", port, err)
		}
	}
}

func TestClientPasswordUserinfoPreservesLiteralOctets(t *testing.T) {
	for _, scheme := range []string{"trojan", "hy2", "hysteria2"} {
		for _, password := range []string{"a+b", "a:b", "a%2Bb", "a@b", "a b"} {
			link := (&url.URL{Scheme: scheme, User: url.User(password), Host: "127.0.0.1:443"}).String()
			result, err := ImportClientProfiles(link)
			if err != nil {
				t.Fatal(err)
			}
			var config struct {
				Outbounds []struct {
					Settings struct{ Password string } `json:"settings"`
					Stream   struct {
						Hysteria struct{ Auth string } `json:"hysteriaSettings"`
					} `json:"streamSettings"`
				} `json:"outbounds"`
			}
			if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
				t.Fatal(err)
			}
			actual := config.Outbounds[0].Settings.Password
			if scheme != "trojan" {
				actual = config.Outbounds[0].Stream.Hysteria.Auth
			}
			if actual != password {
				t.Fatalf("%s password changed: want %q, got %q", scheme, password, actual)
			}
		}
	}
}

func TestBareKCPLinksBuildWithoutRemovedOptions(t *testing.T) {
	for _, header := range []string{"", "none"} {
		qr, _ := json.Marshal(map[string]any{"add": "127.0.0.1", "port": 443, "id": "00000000-0000-4000-8000-000000000001", "net": "kcp", "type": header})
		for _, input := range []string{
			"vmess://" + base64.StdEncoding.EncodeToString(qr),
			"vmess://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=kcp&headerType=" + header,
			"trojan://fixture@127.0.0.1:443?type=kcp&security=none&headerType=" + header,
		} {
			if _, err := ImportClientProfiles(input); err != nil {
				t.Fatalf("bare KCP import failed: %v", err)
			}
		}
	}
}

// yaml.v3 limits aliasing per decoder, but each proxy is decoded on its own, so
// one anchor reused by many proxies would multiply without a document-wide cap.
func TestClashAliasExpansionIsBoundedAcrossProxies(t *testing.T) {
	var text strings.Builder
	text.WriteString("proxies:\n - {name: p0, type: vmess, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, network: ws, ws-opts: {headers: &h {")
	for i := range 3000 {
		fmt.Fprintf(&text, "h%d: v, ", i)
	}
	text.WriteString("x: v}}}\n")
	alpn := strings.Repeat("h2, ", 70) + "h2"
	for i := 1; i < 60; i++ {
		fmt.Fprintf(&text, " - {name: p%d, type: vmess, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, alpn: [%s], network: ws, ws-opts: {headers: *h}}\n", i, alpn)
	}
	if _, err := ImportClientProfiles(text.String()); err == nil || !strings.Contains(err.Error(), "aliases expand too far") {
		t.Fatalf("expected the expansion cap, got %v", err)
	}
}

// The expansion cap charged nodes only when they were popped, so aliases of their
// own anchor queued 399 more nodes for every two charged: 1.6 KB allocated 2 GiB.
func TestClashSelfReferencingAliasIsRejectedInBoundedMemory(t *testing.T) {
	text := "proxies:\n  - &a [" + strings.Repeat("*a, ", 399) + "*a]\n"
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	_, err := ImportClientProfiles(text)
	runtime.ReadMemStats(&after)
	if err == nil || !strings.Contains(err.Error(), "aliases expand too far") {
		t.Fatalf("expected the expansion cap, got %v", err)
	}
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 16<<20 {
		t.Fatalf("rejecting %d bytes of aliases allocated %d MiB", len(text), allocated>>20)
	}
}

func TestClashHTTPUpgradeMovesHostAndPreservesHeaders(t *testing.T) {
	for _, hostKey := range []string{"Host", "host", "HOST"} {
		input := "proxies:\n - {name: fixture, type: vmess, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, network: httpupgrade, http-upgrade-opts: {path: /fixture, headers: {" + hostKey + ": front.example, X-Fixture: retained}}}"
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		var config struct {
			Outbounds []struct {
				Stream struct {
					Upgrade struct {
						Host    string
						Path    string
						Headers map[string]string
					} `json:"httpupgradeSettings"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
			t.Fatal(err)
		}
		upgrade := config.Outbounds[0].Stream.Upgrade
		if upgrade.Host != "front.example" || upgrade.Path != "/fixture" || !reflect.DeepEqual(upgrade.Headers, map[string]string{"X-Fixture": "retained"}) {
			t.Fatal("HTTPUpgrade host, path or remaining headers changed")
		}
	}
}

func TestHysteriaFinalMaskIsPreserved(t *testing.T) {
	mask := `{"udp":[{"type":"salamander","settings":{"password":"fixture-mask"}}]}`
	result, err := ImportClientProfiles("hy2://fixture@127.0.0.1:443?fm=" + url.QueryEscape(mask))
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Outbounds []struct {
			Stream struct {
				Mask struct {
					UDP []struct {
						Type     string `json:"type"`
						Settings struct {
							Password string `json:"password"`
						} `json:"settings"`
					} `json:"udp"`
				} `json:"finalmask"`
			} `json:"streamSettings"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
		t.Fatal(err)
	}
	udp := config.Outbounds[0].Stream.Mask.UDP
	if len(udp) != 1 || udp[0].Type != "salamander" || udp[0].Settings.Password != "fixture-mask" {
		t.Fatal("explicit Hy2 mask was lost")
	}
}

func TestHysteriaKeepsItsCertificatePin(t *testing.T) {
	pin := strings.TrimSuffix(strings.Repeat("AB:", 32), ":")
	result, err := ImportClientProfiles("hy2://fixture@127.0.0.1:443?insecure=1&sni=example.com&pinSHA256=" + url.QueryEscape(pin))
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Outbounds []struct {
			Stream struct {
				TLS struct {
					AllowInsecure bool   `json:"allowInsecure"`
					Pin           string `json:"pinnedPeerCertSha256"`
				} `json:"tlsSettings"`
			} `json:"streamSettings"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
		t.Fatal(err)
	}
	if got := config.Outbounds[0].Stream.TLS.Pin; got != pin {
		t.Fatalf("hy2 pinSHA256 was dropped: got %q", got)
	}
}

// A SIP002 plugin changes the transport; dropping it imports a server that never works.
func TestShadowsocksPluginLinksMapOrFail(t *testing.T) {
	user := base64.RawURLEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:fixture"))
	link := func(plugin string) string {
		return "ss://" + user + "@127.0.0.1:8388/?plugin=" + url.QueryEscape(plugin) + "#Plugin"
	}
	for _, plugin := range []string{"obfs-local;obfs=http;obfs-host=example.com", "v2ray-plugin;mode=quic", "v2ray-plugin;cert=/ca.pem"} {
		if _, err := ImportClientProfiles(link(plugin)); err == nil {
			t.Fatalf("imported %q without its plugin", plugin)
		}
	}
	result, err := ImportClientProfiles(link("v2ray-plugin;mode=websocket;tls;host=cdn.example;path=/ws;mux=1"))
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Outbounds []struct {
			Stream struct {
				Network  string `json:"network"`
				Security string `json:"security"`
				WS       struct {
					Host string `json:"host"`
					Path string `json:"path"`
				} `json:"wsSettings"`
				TLS struct {
					ServerName string `json:"serverName"`
				} `json:"tlsSettings"`
			} `json:"streamSettings"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
		t.Fatal(err)
	}
	stream := config.Outbounds[0].Stream
	if stream.Network != "ws" && stream.Network != "websocket" || stream.Security != "tls" ||
		stream.WS.Host != "cdn.example" || stream.WS.Path != "/ws" || stream.TLS.ServerName != "cdn.example" {
		t.Fatalf("v2ray-plugin websocket was not mapped: %+v", stream)
	}
}

// Many clients write SIP002 plugin options and paths with a bare ';', which net/url
// drops along with the whole parameter.
func TestShareLinkParametersKeepABareSemicolon(t *testing.T) {
	user := base64.RawURLEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:fixture"))
	if _, err := ImportClientProfiles("ss://" + user + "@127.0.0.1:8388/?plugin=obfs-local;obfs=http;obfs-host=example.com#Plugin"); err == nil {
		t.Fatal("imported an obfs link without its plugin")
	}
	for link, path := range map[string]string{
		"ss://" + user + "@127.0.0.1:8388/?plugin=v2ray-plugin;mode=websocket;host=cdn.example;path=/ws#Plugin": "/ws",
		"vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=ws&host=cdn.example&path=/a;b#WS":      "/a;b",
	} {
		result, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatal(link, err)
		}
		var config struct {
			Outbounds []struct {
				Stream struct {
					WS struct {
						Path string `json:"path"`
					} `json:"wsSettings"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(result.Profiles[0].Config, &config); err != nil {
			t.Fatal(err)
		}
		if got := config.Outbounds[0].Stream.WS.Path; got != path {
			t.Fatalf("%s: path %q, want %q", link, got, path)
		}
	}
}

func TestTelegramLinksAreExplicitHandoffs(t *testing.T) {
	input := "https://t.me/proxy?server=proxy.example.com&port=443&secret=000102030405060708090a0b0c0d0e0f"
	result, err := ImportClientProfiles(input)
	if err != nil {
		t.Fatal(err)
	}
	if result.Profiles[0].Format != "telegram" || len(result.Profiles[0].Config) != 0 {
		t.Fatal("Telegram service became a VPN configuration")
	}
	if _, ok := TelegramProxyURL(result.Profiles[0].URL); !ok {
		t.Fatal("invalid canonical Telegram URL")
	}
	for _, bad := range []string{input + "&server=other.example.com", "https://evil.example/proxy?server=proxy.example.com&port=443&secret=000102030405060708090a0b0c0d0e0f", "tg://proxy?server=proxy.example.com&port=0&secret=000102030405060708090a0b0c0d0e0f"} {
		if _, ok := TelegramProxyURL(bad); ok {
			t.Fatal("invalid handoff accepted")
		}
	}
}

func TestShareLinksKeepEveryInsecureSpelling(t *testing.T) {
	for _, base := range []string{
		"vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&sni=example.com&type=tcp",
		"trojan://secret@example.com:443?security=tls&sni=example.com",
	} {
		for query, want := range map[string]bool{"insecure=1": true, "allowInsecure=1": true, "allowInsecure=true": true, "allow_insecure=1": true, "allowInsecure=0": false} {
			result, err := ImportClientProfiles(base + "&" + query)
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.Contains(string(result.Profiles[0].Config), `"allowInsecure":true`); got != want {
				t.Fatalf("%s&%s: allowInsecure %v, want %v", base, query, got, want)
			}
		}
	}
}

func TestWebPagesAreNotHTTPProxies(t *testing.T) {
	for _, page := range []string{
		"https://t.me/proxy?server=proxy.example.com&port=443&secret=000102030405060708090a0b0c0d0e0f&server=other.example.com",
		"https://t.me/socks?server=203.0.113.7&port=1080&user=u&pass=p",
		"https://www.example.com/support?lang=en",
		"vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=none#VPN\nhttp://user:pass@127.0.0.1:8080/status",
	} {
		if result, err := ImportClientProfiles(page); err == nil {
			t.Fatalf("%q imported as %d profiles", page, len(result.Profiles))
		}
	}
	for _, proxy := range []string{"https://user:pass@127.0.0.1:8443/", "http://127.0.0.1:8080?sni=proxy.example"} {
		if _, err := ImportClientProfiles(proxy); err != nil {
			t.Fatalf("%q: %v", proxy, err)
		}
	}
}

func TestWireGuardAndAmneziaExports(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	base := "[Interface]\nPrivateKey=" + key + "\nAddress=10.20.0.2/32,fd00::2/128\nDNS=10.20.0.1\nMTU=1280\n"
	peer := "[Peer]\nPublicKey=" + key + "\nPresharedKey=" + key + "\nEndpoint=[2001:db8::1]:51820\nAllowedIPs=0.0.0.0/0,::/0\nPersistentKeepalive=25\n"
	advanced := "Jc=4\nJmin=40\nJmax=80\nS1=16\nS2=17\nS3=18\nS4=19\nH1=100-110\nH2=200-210\nH3=300-310\nH4=400-410\nI1=<b 0x1234>;<r 8>\nI2=<r 8>\nI3=<r 9>\nI4=<r 10>\nI5=<r 11>\nHeaderProtectionKey=" + key + "\nContentPaddingAddition=4-8\nRekeyAfterTime=120-125\nRekeyTimeout=5-7\nRejectAfterTime=180-190\nKeepaliveTimeout=10-15\nMaxHandshakeAttempts=18-20\nRandomTrailers=on\nDisableCookies=on\n"
	for _, input := range []string{base + peer, "# Exported client\n; WireGuard\n\n" + base + peer, base + advanced + peer, "vpn://" + base64.RawURLEncoding.EncodeToString([]byte(base+advanced+peer))} {
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Fatal(err)
		}
		if err := validateClientProfile(result.Profiles[0].Config); err != nil {
			t.Fatal(err)
		}
		var root map[string]any
		json.Unmarshal(result.Profiles[0].Config, &root)
		outbound := root["outbounds"].([]any)[0].(map[string]any)
		settings := outbound["settings"].(map[string]any)
		if settings["mtu"] != float64(1280) || len(settings["address"].([]any)) != 2 || root["dns"] == nil {
			t.Fatal("interface settings lost")
		}
		if strings.Contains(input, "Jc=") || strings.HasPrefix(input, "vpn://") {
			if outbound["protocol"] != "amneziawg" {
				t.Fatal("AmneziaWG was downgraded")
			}
			obf := settings["amnezia"].(map[string]any)
			if len(obf) != 25 || obf["random_trailers"] != "true" || obf["disable_cookies"] != "true" || obf["h1"] != "100-110" || obf["i1"] != "<b 0x1234>;<r 8>" {
				t.Fatalf("3.1 fields lost (%d)", len(obf))
			}
		}
	}
	for _, invalid := range []string{strings.Replace(base+peer, key, "short", 1), base + "Jmin=90\nJmax=10\n" + peer, base + "PostUp=run-a-command\n" + peer, base + "S1=65536\n" + peer, base + "H1=20-10\n" + peer, base + "H1=100-200\nH2=150-300\n" + peer, strings.Replace(base+peer, ":51820", ":65536", 1)} {
		if _, err := ImportClientProfiles(invalid); err == nil {
			t.Fatal("invalid WireGuard settings accepted")
		}
	}
}

func TestStockClashProfilePreservesManualGroupAndRules(t *testing.T) {
	input := "proxies:\n  - {name: one, type: socks5, server: 127.0.0.1, port: 1080}\n  - {name: two, type: http, server: 127.0.0.1, port: 8080}\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [one, two, DIRECT]}\nrules:\n  - DOMAIN-SUFFIX,example.org,DIRECT\n  - MATCH,PROXY\ndns:\n  enable: true\n  nameserver: [1.1.1.1]\n"
	result, err := ImportClientProfiles(input)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Profiles) != 1 {
		t.Fatal("Clash graph was flattened")
	}
	var root map[string]any
	json.Unmarshal(result.Profiles[0].Config, &root)
	groups := root["elarniGroups"].([]any)
	if len(groups) != 1 || groups[0].(map[string]any)["selected"] != "one" {
		t.Fatal("manual group lost its default selection")
	}
	rules := root["routing"].(map[string]any)["rules"].([]any)
	if len(rules) != 2 || rules[1].(map[string]any)["outboundTag"] != "PROXY" || root["dns"] == nil {
		t.Fatal("Clash policy lost")
	}
	if _, err := ImportClientProfiles(strings.Replace(input, "MATCH,PROXY", "MATCH,MISSING", 1)); err == nil {
		t.Fatal("missing routing target accepted")
	}
	for _, change := range []struct{ before, after string }{
		{"type: select", "type: select, filter: ignored"},
		{"MATCH,PROXY", "IP-CIDR,192.0.2.0/24,DIRECT,no-resolve"},
		{"type: select", "type: url-test"},
	} {
		if _, err := ImportClientProfiles(strings.Replace(input, change.before, change.after, 1)); err == nil {
			t.Fatal("unsupported Clash graph semantics were silently discarded")
		}
	}
}

// An unbracketed IPv6 host splits at its last colon into another host and port.
func TestUnbracketedIPv6HostIsRejected(t *testing.T) {
	for _, link := range []string{"trojan://fixture@2001:db8::1#IPv6", "trojan://fixture@2001:db8::1:443#IPv6"} {
		if result, err := ImportClientProfiles(link); err == nil {
			t.Fatalf("%s imported as %s", link, result.Profiles[0].Config)
		}
	}
	if _, err := ImportClientProfiles("trojan://fixture@[2001:db8::1]:443#IPv6"); err != nil {
		t.Fatal("bracketed IPv6 host", err)
	}
}

// Clash's LAN is the private ranges, which geofiles name "private"; they have no LAN code.
func TestClashLanRuleMatchesPrivateAddresses(t *testing.T) {
	rule, err := clashRoutingRule("GEOIP,LAN,DIRECT", map[string]bool{"DIRECT": true})
	if err != nil {
		t.Fatal(err)
	}
	if ip := rule["ip"].([]string); len(ip) != 1 || ip[0] != "geoip:private" {
		t.Fatalf("GEOIP,LAN became %v", ip)
	}
}

func TestImportedProfilesCannotReadCertificateFilesOrLogTLSKeys(t *testing.T) {
	for _, tls := range []string{`{"certificates":[{"certificateFile":"/never-read/client.pem"}]}`, `{"certificates":[{"keyFile":"/never-read/client.key"}]}`, `{"masterKeyLog":"/never-write/keys.log"}`} {
		profile := `{"outbounds":[{"protocol":"trojan","settings":{"address":"127.0.0.1","port":443,"password":"fixture"},"streamSettings":{"security":"tls","tlsSettings":` + tls + `}}]}`
		if _, err := ImportClientProfiles(profile); err == nil {
			t.Fatal("profile with local file side effects accepted")
		}
	}
	for _, fixture := range []struct{ name, security, settings string }{
		{"reality", "reality", `"fingerprint":"chrome","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverName":"example.org","masterKeyLog":"/never-write/keys.log"`},
		{"case-insensitive logging", "tls", `"MasterKeyLog":"/never-write/keys.log"`},
		{"case-insensitive certificate", "tls", `"Certificates":[{"CertificateFile":"/never-read/client.pem"}]`},
		{"case-insensitive private key", "tls", `"certificates":[{"KeyFile":"/never-read/client.key"}]`},
		{"nested transport", "tls", `"serverName":"example.org"`},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			settings := fixture.settings
			if fixture.name == "nested transport" {
				settings += `},"network":"xhttp","xhttpSettings":{"extra":{"downloadSettings":{"security":"reality","realitySettings":{"fingerprint":"chrome","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverName":"example.org","masterKeyLog":"/never-write/keys.log"}}}`
			}
			profile := `{"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"},"streamSettings":{"security":"` + fixture.security + `","` + fixture.security + `Settings":{` + settings + `}}}]}`
			if !json.Valid([]byte(profile)) {
				t.Fatal("invalid regression fixture")
			}
			if _, err := ImportClientProfiles(profile); err == nil {
				t.Fatal("profile with local file side effects accepted")
			}
		})
	}
	for _, security := range []string{"tls", "reality"} {
		profile := `{"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"},"streamSettings":{"security":"` + security + `","` + security + `Settings":{"fingerprint":"chrome","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverName":"example.org"}}}]}`
		if _, err := ImportClientProfiles(profile); err != nil {
			t.Fatalf("safe %s control rejected: %v", security, err)
		}
	}
}

func TestAdvancedShareAndClashFieldsSurviveImport(t *testing.T) {
	key := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	verification := base64.RawURLEncoding.EncodeToString(make([]byte, 1952))
	encryption := "mlkem768x25519plus.native.1rtt." + key
	extra := `{"headers":{"X-Fixture":"preserved"},"xPaddingBytes":"20-40","xmux":{"maxConcurrency":"2-4"},"downloadSettings":{"address":"download.example.com","port":8443,"network":"xhttp","security":"tls","tlsSettings":{"serverName":"download.example.com"},"xhttpSettings":{"path":"/down"}}}`
	fixtures := []struct {
		name, input string
		expected    map[string]any
	}{
		{"TLS and XHTTP link", "vless://00000000-0000-4000-8000-000000000001@upload.example.com:443?encryption=" + url.QueryEscape(encryption) + "&security=tls&sni=front.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome&ech=AA%3D%3D&pcs=" + strings.Repeat("01", 32) + "&vcn=front.example.com&type=xhttp&path=%2Fup&mode=auto&extra=" + url.QueryEscape(extra), map[string]any{
			"settings.encryption": encryption, "streamSettings.tlsSettings.serverName": "front.example.com", "streamSettings.tlsSettings.alpn": []any{"h2", "http/1.1"}, "streamSettings.tlsSettings.echConfigList": "AA==", "streamSettings.tlsSettings.pinnedPeerCertSha256": strings.Repeat("01", 32), "streamSettings.tlsSettings.verifyPeerCertByName": "front.example.com",
			"streamSettings.xhttpSettings.path": "/up", "streamSettings.xhttpSettings.extra.headers.X-Fixture": "preserved", "streamSettings.xhttpSettings.extra.downloadSettings.address": "download.example.com", "streamSettings.xhttpSettings.extra.xmux.maxConcurrency": "2-4",
		}},
		{"VLESS gRPC URL", "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443?security=tls&sni=tls.example.com&alpn=h2&type=grpc&serviceName=fixture%2Fservice&authority=virtual.example.com&mode=multi", map[string]any{
			"streamSettings.network": "grpc", "streamSettings.grpcSettings.serviceName": "fixture/service", "streamSettings.grpcSettings.authority": "virtual.example.com", "streamSettings.grpcSettings.multiMode": true,
			"streamSettings.tlsSettings.serverName": "tls.example.com", "streamSettings.tlsSettings.alpn": []any{"h2"},
		}},
		{"REALITY link", "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=reality&flow=xtls-rprx-vision&fp=chrome&sni=front.example.com&pbk=" + key + "&sid=0123456789abcdef&spx=%2Fspider&pqv=" + verification, map[string]any{
			"streamSettings.realitySettings.mldsa65Verify": verification, "settings.flow": "xtls-rprx-vision", "streamSettings.realitySettings.publicKey": key, "streamSettings.realitySettings.shortId": "0123456789abcdef", "streamSettings.realitySettings.spiderX": "/spider", "streamSettings.realitySettings.serverName": "front.example.com",
		}},
		{"Clash XHTTP", `proxies:
 - name: fixture
   type: vless
   server: upload.example.com
   port: 443
   uuid: 00000000-0000-4000-8000-000000000001
   tls: true
   servername: front.example.com
   ech-opts: {enable: true, config: AA==}
   network: xhttp
   xhttp-opts:
     path: /up
     mode: auto
     session-id-placement: header
     session-id-key: X-Session
     x-padding-bytes: 20-40
     reuse-settings: {max-concurrency: 2-4, h-keep-alive-period: 20}
     download-settings:
       server: download.example.com
       port: 8443
       tls: true
       servername: download-front.example.com
       path: /down
`, map[string]any{
			"streamSettings.tlsSettings.echConfigList": "AA==", "streamSettings.xhttpSettings.sessionIDKey": "X-Session", "streamSettings.xhttpSettings.xmux.maxConcurrency": "2-4", "streamSettings.xhttpSettings.xmux.hKeepAlivePeriod": float64(20), "streamSettings.xhttpSettings.downloadSettings.address": "download.example.com", "streamSettings.xhttpSettings.downloadSettings.tlsSettings.serverName": "download-front.example.com", "streamSettings.xhttpSettings.downloadSettings.xhttpSettings.path": "/down",
		}},
		{"Clash SS TLS", `proxies:
 - {name: fixture, type: ss, server: 127.0.0.1, port: 443, cipher: chacha20-ietf-poly1305, password: fixture, tls: true, servername: front.example.com}
`, map[string]any{"streamSettings.security": "tls", "streamSettings.tlsSettings.serverName": "front.example.com"}},
		{"Clash SS plugin TLS", `proxies:
 - name: fixture
   type: ss
   server: 127.0.0.1
   port: 443
   cipher: chacha20-ietf-poly1305
   password: fixture
   plugin: v2ray-plugin
   plugin-opts: {mode: websocket, tls: true, host: front.example.com, path: /ws, skip-cert-verify: true}
`, map[string]any{"streamSettings.security": "tls", "streamSettings.tlsSettings.serverName": "front.example.com", "streamSettings.tlsSettings.allowInsecure": true}},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.name, func(t *testing.T) {
			imported, err := ImportClientProfiles(fixture.input)
			if err != nil {
				t.Fatal(err)
			}
			var profile map[string]any
			if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
				t.Fatal(err)
			}
			outbound := profile["outbounds"].([]any)[0]
			for path, want := range fixture.expected {
				actual := outbound
				for _, key := range strings.Split(path, ".") {
					object, ok := actual.(map[string]any)
					if !ok {
						t.Fatalf("missing %s", path)
					}
					actual = object[key]
				}
				if !reflect.DeepEqual(actual, want) {
					t.Fatalf("%s changed: got %v; want %v", path, actual, want)
				}
			}
		})
	}
	invalid := `proxies:
 - {name: fixture, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, ech-opts: {enable: true, config: AA==, unknown-policy: true}}
`
	if _, err := ImportClientProfiles(invalid); err == nil {
		t.Fatal("unknown nested security policy discarded")
	}
}

func TestClashCertificateFingerprintIsAPinNotAUTLSName(t *testing.T) {
	// Mihomo's fingerprint is the SHA-256 of the server certificate; client-fingerprint is uTLS.
	pin := strings.TrimSuffix(strings.Repeat("AB:", 32), ":")
	tls := "tls: true, servername: front.example.com, skip-cert-verify: true, fingerprint: '" + pin + "', client-fingerprint: chrome"
	for name, fixture := range map[string]struct{ input, tls string }{
		"vless":     {"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, " + tls + "}", "streamSettings.tlsSettings"},
		"trojan":    {"{name: f, type: trojan, server: 127.0.0.1, port: 443, password: p, " + tls + "}", "streamSettings.tlsSettings"},
		"hysteria2": {"{name: f, type: hysteria2, server: 127.0.0.1, port: 443, password: p, " + tls + "}", "streamSettings.tlsSettings"},
		"ss plugin": {"{name: f, type: ss, server: 127.0.0.1, port: 443, cipher: chacha20-ietf-poly1305, password: p, plugin: v2ray-plugin, plugin-opts: {mode: websocket, tls: true, host: front.example.com, skip-cert-verify: true, fingerprint: '" + pin + "'}}", "streamSettings.tlsSettings"},
		"xhttp download": {"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, network: xhttp, xhttp-opts: {path: /up, download-settings: {server: 127.0.0.1, port: 443, " + tls + ", path: /down}}}",
			"streamSettings.xhttpSettings.downloadSettings.tlsSettings"},
	} {
		imported, err := ImportClientProfiles("proxies:\n - " + fixture.input + "\n")
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var profile map[string]any
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		var settings any = profile["outbounds"].([]any)[0]
		for _, key := range strings.Split(fixture.tls, ".") {
			settings = settings.(map[string]any)[key]
		}
		tlsSettings := settings.(map[string]any)
		if tlsSettings["pinnedPeerCertSha256"] != pin || (name != "ss plugin" && tlsSettings["fingerprint"] != "chrome") {
			t.Fatalf("%s: certificate pin not kept: %v", name, tlsSettings)
		}
	}
}

func TestBootstrapHostsUseCorePatternsAliasesAndBlocking(t *testing.T) {
	profile := `{"dns":{"hosts":{"domain:provider.test":"192.0.2.1","regexp:^edge[0-9]+\\.provider\\.test$":"2001:db8::1","alias.test":"edge2.provider.test","external-alias.test":"lookup.test","blocked.test":"#3","empty.test":[]}}}`
	mappings, err := ProfileHostMappings(profile, []string{"edge2.provider.test.", "alias.test", "external-alias.test", "blocked.test", "empty.test", "unmapped.test"})
	if err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"edge2.provider.test.", "alias.test"} {
		addresses := mappings[host].(map[string]any)["addresses"].([]string)
		slices.Sort(addresses)
		if !slices.Equal(addresses, []string{"192.0.2.1", "2001:db8::1"}) {
			t.Fatal("core host patterns or alias accumulation changed")
		}
	}
	if mappings["external-alias.test"].(map[string]any)["alias"] != "lookup.test" {
		t.Fatal("external DNS alias lost")
	}
	for _, host := range []string{"blocked.test", "empty.test"} {
		if mappings[host].(map[string]any)["blocked"] != true {
			t.Fatal("blocked host could fall back to system DNS")
		}
	}
	if _, ok := mappings["unmapped.test"]; ok {
		t.Fatal("unmapped host became a provider override")
	}
}

// Standard base64 userinfo has to percent-encode '/' and '=' inside a URL.
func TestShadowsocksStandardBase64UserInfoWithEscapes(t *testing.T) {
	for _, link := range []string{"ss://YWVzLTI1Ni1nY206eD4%2FeQ%3D%3D@127.0.0.1:8388#fixture", "ss://YWVzLTI1Ni1nY206eD4_eQ@127.0.0.1:8388#fixture"} {
		imported, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		var profile struct {
			Outbounds []struct {
				Settings map[string]any `json:"settings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		settings := profile.Outbounds[0].Settings
		if servers, ok := settings["servers"].([]any); ok {
			settings = servers[0].(map[string]any)
		}
		if settings["method"] != "aes-256-gcm" || settings["password"] != "x>?y" {
			t.Fatalf("%s: credentials changed: %v", link, settings)
		}
	}
}

// A userinfo '+' is a plus sign; only query strings turn it into a space.
func TestVLESSAndVMessIDsKeepPlusSigns(t *testing.T) {
	for _, link := range []string{"vless://fixture+id@127.0.0.1:443?encryption=none", "vmess://fixture+id@127.0.0.1:443"} {
		imported, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		if !strings.Contains(string(imported.Profiles[0].Config), `"fixture+id"`) {
			t.Fatalf("%s: id changed: %s", link, imported.Profiles[0].Config)
		}
	}
}

// The Hysteria 2 URI lists hopping ports in the authority: host:443,5000-6000.
func TestHysteria2MultiPortAuthorityHops(t *testing.T) {
	query, err := ImportClientProfiles("hysteria2://secret@127.0.0.1:443?ports=443,5000-6000#hop")
	if err != nil {
		t.Fatal(err)
	}
	// url.Parse accepts any scheme case, so the port-list fallback must too.
	for _, link := range []string{"hysteria2://secret@127.0.0.1:443,5000-6000/#hop", "hy2://secret@127.0.0.1:443,5000-6000?ports=443,5000-6000#hop", "HY2://secret@127.0.0.1:443,5000-6000/#hop"} {
		imported, err := ImportClientProfiles(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		if string(imported.Profiles[0].Config) != string(query.Profiles[0].Config) {
			t.Fatalf("%s:\n%s\nwant\n%s", link, imported.Profiles[0].Config, query.Profiles[0].Config)
		}
	}
}

// v2rayN writes the hop range and interval as mport and mportHopInt.
func TestHysteria2V2rayNHopKeys(t *testing.T) {
	want, err := ImportClientProfiles("hysteria2://secret@example.com:443?sni=example.com&ports=20000-30000&hop-interval=30#hop")
	if err != nil {
		t.Fatal(err)
	}
	got, err := ImportClientProfiles("hysteria2://secret@example.com:443?sni=example.com&mport=20000-30000&mportHopInt=30#hop")
	if err != nil {
		t.Fatal(err)
	}
	if string(got.Profiles[0].Config) != string(want.Profiles[0].Config) {
		t.Fatalf("v2rayN hop keys:\n%s\nwant\n%s", got.Profiles[0].Config, want.Profiles[0].Config)
	}
}

// Xray v26.10 hops Hysteria2 ports through a udphop mask under the
// obfuscation and ignores the old quicParams.udpHop, which left an imported
// port-hopping server on one port. Hysteria hops to a new port from a new
// local socket.
func TestHysteria2PortHoppingBuildsTheUDPHopMask(t *testing.T) {
	imported, err := ImportClientProfiles("hysteria2://secret@127.0.0.1:443?sni=example.com&ports=20000-20009&hop-interval=15&obfs=salamander&obfs-password=fixture#hop")
	if err != nil {
		t.Fatal(err)
	}
	var profile conf.Config
	if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
		t.Fatal(err)
	}
	built, err := profile.OutboundConfigs[0].Build()
	if err != nil {
		t.Fatal(err)
	}
	sender, err := built.SenderSettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	masks := sender.(*proxyman.SenderConfig).StreamSettings.Udpmasks
	if len(masks) != 2 {
		t.Fatalf("%d UDP masks, want salamander then udphop:\n%s", len(masks), imported.Profiles[0].Config)
	}
	hop, err := masks[1].GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	config, ok := hop.(*udphop.Config)
	if !ok || !config.Local || !config.Remote || config.RemoteOnce || config.IntervalMin != 15 || config.IntervalMax != 15 ||
		!slices.Equal(config.RemotePorts, []uint32{20000, 20001, 20002, 20003, 20004, 20005, 20006, 20007, 20008, 20009}) {
		t.Fatalf("second mask %T %v", hop, hop)
	}
	if obfs, err := masks[0].GetInstance(); err != nil || reflect.TypeOf(obfs) != reflect.TypeOf(&salamander.Config{}) {
		t.Fatalf("first mask %T, %v", obfs, err)
	}
	links, err := ConvertXrayJsonToShareLinks(imported.Profiles[0].Config)
	if err != nil || !strings.Contains(links, "ports=20000-20009") || !strings.Contains(links, "hop-interval=15") {
		t.Fatalf("exported %q, %v", links, err)
	}
}

// An obfuscation the core cannot apply must not import as plain QUIC.
func TestHysteria2UnsupportedObfuscationIsRefused(t *testing.T) {
	for _, input := range []string{"hysteria2://secret@127.0.0.1:443?obfs=gecko&obfs-password=fixture", "hysteria2://secret@127.0.0.1:443?obfs=salamander",
		"proxies:\n - {name: f, type: hysteria2, server: 127.0.0.1, port: 443, password: secret, obfs: gecko, obfs-password: fixture}\n"} {
		if _, err := ImportClientProfiles(input); err == nil {
			t.Fatalf("%q imported without its obfuscation", input)
		}
	}
	if _, err := ImportClientProfiles("hysteria2://secret@127.0.0.1:443?obfs=salamander&obfs-password=fixture"); err != nil {
		t.Fatal(err)
	}
}

// Mihomo's vmess and vless send the ws Host as SNI when servername is unset; trojan
// falls back to the server.
func TestClashWebSocketHostIsTheDefaultSNI(t *testing.T) {
	for proxy, want := range map[string]string{
		"{name: f, type: vmess, server: 127.0.0.1, port: 443, uuid: 11111111-1111-4111-8111-111111111111, alterId: 0, cipher: auto, tls: true, network: ws, ws-opts: {path: /p, headers: {Host: cdn.example.com}}}": "cdn.example.com",
		"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 11111111-1111-4111-8111-111111111111, tls: true, network: ws, ws-opts: {path: /p, headers: {Host: cdn.example.com}}}":                           "cdn.example.com",
		"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 11111111-1111-4111-8111-111111111111, tls: true, servername: sni.example.com, network: ws, ws-opts: {headers: {Host: cdn.example.com}}}":        "sni.example.com",
		"{name: f, type: trojan, server: 127.0.0.1, port: 443, password: secret, network: ws, ws-opts: {path: /p, headers: {Host: cdn.example.com}}}":                                                               "",
	} {
		imported, err := ImportClientProfiles("proxies:\n - " + proxy + "\n")
		if err != nil {
			t.Fatalf("%s: %v", proxy, err)
		}
		var profile struct {
			Outbounds []struct {
				StreamSettings struct {
					TLSSettings struct {
						ServerName string `json:"serverName"`
					} `json:"tlsSettings"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		if got := profile.Outbounds[0].StreamSettings.TLSSettings.ServerName; got != want {
			t.Errorf("%s: serverName %q, want %q", proxy, got, want)
		}
	}
}

// Mihomo fetches the ECH config over its own DNS when ech-opts names none; importing
// such a proxy without ECH would send the real server name in the clear.
func TestClashECHWithoutAConfigListIsRefused(t *testing.T) {
	const ech = "ech-opts: {enable: true}"
	for name, input := range map[string]string{
		"vless":          "{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, servername: front.example.com, " + ech + "}",
		"trojan":         "{name: f, type: trojan, server: 127.0.0.1, port: 443, password: p, sni: front.example.com, " + ech + "}",
		"ss plugin":      "{name: f, type: ss, server: 127.0.0.1, port: 443, cipher: chacha20-ietf-poly1305, password: p, plugin: v2ray-plugin, plugin-opts: {mode: websocket, tls: true, host: front.example.com, " + ech + "}}",
		"xhttp download": "{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, network: xhttp, xhttp-opts: {path: /up, download-settings: {server: 127.0.0.1, port: 443, tls: true, servername: front.example.com, " + ech + ", path: /down}}}",
	} {
		if _, err := ImportClientProfiles("proxies:\n - " + input + "\n"); err == nil {
			t.Errorf("%s: imported without its ECH", name)
		}
	}
	for input, want := range map[string]string{
		"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, servername: front.example.com, ech-opts: {enable: true, config: AEX+DQBB}}": "AEX+DQBB",
		"{name: f, type: vless, server: 127.0.0.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, " + ech + "}":                                                                          "",
	} {
		imported, err := ImportClientProfiles("proxies:\n - " + input + "\n")
		if err != nil {
			t.Fatalf("%s: %v", input, err)
		}
		var profile struct {
			Outbounds []struct {
				StreamSettings struct {
					TLSSettings struct {
						ECHConfigList string `json:"echConfigList"`
					} `json:"tlsSettings"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		if got := profile.Outbounds[0].StreamSettings.TLSSettings.ECHConfigList; got != want {
			t.Errorf("%s: echConfigList %q, want %q", input, got, want)
		}
	}
}

// Apps store the migrated URL and later re-check it: no raw space, at most 16 KiB escaped.
func TestSubscriptionMigrationURLIsStorable(t *testing.T) {
	const source = "https://old.example/sub?token=ok"
	for _, hint := range []map[string]string{
		{"new-url": "https://new.example/sub?token=a b"},
		{"new-url": "https://new.example/" + strings.Repeat("\u00e9", 6000)},
	} {
		if got, err := SubscriptionMigrationURL(source, nil, hint); err == nil {
			t.Errorf("%.40q migrated to %d bytes: %.60q", hint["new-url"], len(got), got)
		}
	}
	if got, err := SubscriptionMigrationURL("https://old.example/"+strings.Repeat("\u00e9", 6000), nil, map[string]string{"new-domain": "new.example"}); err == nil {
		t.Errorf("domain move kept a path that escapes to %d bytes", len(got))
	}
	for hint, want := range map[string]string{"https://new.example/a b": "https://new.example/a%20b", "https://new.example/\u00e9": "https://new.example/%C3%A9"} {
		if got, err := SubscriptionMigrationURL(source, nil, map[string]string{"new-url": hint}); err != nil || got != want {
			t.Errorf("%q: %q %v, want %q", hint, got, err, want)
		}
	}
}

// Mihomo reads a bare up/down as Mbps, B as bytes and b as bits with decimal
// prefixes, ignores other forms, and accepts a hop-interval range, raising its
// start to 5 s. Passing the strings to Xray's parser rejected a bare up/down,
// read MBps as megabits and refused a range.
func TestClashHysteria2BandwidthAndHopIntervalFollowMihomo(t *testing.T) {
	for proxy, want := range map[string][4]uint64{
		"up: 100, down: 200":                                   {12500000, 25000000},
		"up: '10 MBps', down: '20 Mbps'":                       {10000000, 2500000},
		"up: '100 mbps', down: 1Gbps":                          {0, 125000000},
		"ports: '20000-30000', hop-interval: '15-30'":          {0, 0, 15, 30},
		"ports: '20000-30000', hop-interval: 3":                {0, 0, 5, 5},
		"ports: '20000-30000', hop-interval: 40, up: '1 Gbps'": {125000000, 0, 40, 40},
	} {
		imported, err := ImportClientProfiles("proxies:\n - {name: h, type: hysteria2, server: 127.0.0.1, port: 443, password: pw, " + proxy + "}\n")
		if err != nil {
			t.Fatalf("%s: %v", proxy, err)
		}
		var profile struct {
			Outbounds []struct {
				StreamSettings struct {
					FinalMask struct {
						QuicParams struct {
							BrutalUp   conf.Bandwidth `json:"brutalUp"`
							BrutalDown conf.Bandwidth `json:"brutalDown"`
						} `json:"quicParams"`
						Udp []struct {
							Type     string `json:"type"`
							Settings struct {
								Interval conf.Int32Range `json:"interval"`
							} `json:"settings"`
						} `json:"udp"`
					} `json:"finalmask"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		mask := profile.Outbounds[0].StreamSettings.FinalMask
		up, upErr := mask.QuicParams.BrutalUp.Bps()
		down, downErr := mask.QuicParams.BrutalDown.Bps()
		var hop conf.Int32Range
		for _, udp := range mask.Udp {
			if udp.Type == "udphop" {
				hop = udp.Settings.Interval
			}
		}
		got := [4]uint64{up, down, uint64(hop.From), uint64(hop.To)}
		if upErr != nil || downErr != nil || got != want {
			t.Errorf("%s: up, down, hop = %v (%v, %v), want %v", proxy, got, upErr, downErr, want)
		}
	}
}

// v2rayN's VMess QR carries the gRPC authority in host and the certificate
// policy in insecure, vcn and pcs; dropping them left a pinned server unreachable.
func TestVMessQRKeepsGRPCAuthorityAndCertificatePolicy(t *testing.T) {
	pin := strings.Repeat("ab", 32)
	qr := `{"v":"2","ps":"g","add":"127.0.0.1","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","net":"grpc","type":"multi",` +
		`"host":"authority.example","path":"svc","tls":"tls","sni":"front.example","insecure":"1","vcn":"real.example","pcs":"` + pin + `"}`
	imported, err := ImportClientProfiles("vmess://" + base64.StdEncoding.EncodeToString([]byte(qr)))
	if err != nil {
		t.Fatal(err)
	}
	var profile struct {
		Outbounds []struct {
			StreamSettings struct {
				GRPCSettings struct {
					Authority   string `json:"authority"`
					ServiceName string `json:"serviceName"`
				} `json:"grpcSettings"`
				TLSSettings struct {
					ServerName           string `json:"serverName"`
					AllowInsecure        bool   `json:"allowInsecure"`
					VerifyPeerCertByName string `json:"verifyPeerCertByName"`
					PinnedPeerCertSha256 string `json:"pinnedPeerCertSha256"`
				} `json:"tlsSettings"`
			} `json:"streamSettings"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
		t.Fatal(err)
	}
	stream := profile.Outbounds[0].StreamSettings
	if stream.GRPCSettings.Authority != "authority.example" || stream.GRPCSettings.ServiceName != "svc" || stream.TLSSettings.ServerName != "front.example" ||
		!stream.TLSSettings.AllowInsecure || stream.TLSSettings.VerifyPeerCertByName != "real.example" || stream.TLSSettings.PinnedPeerCertSha256 != pin {
		t.Fatalf("stream settings %+v", stream)
	}
}

// v2rayN's WireGuard links carry reserved bytes as "1,2,3"; the importer refused
// the whole link, and WARP-style peers need those bytes.
func TestWireGuardLinkKeepsReservedBytes(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	link := "wireguard://" + url.PathEscape(key) + "@127.0.0.1:51820?publickey=" + url.QueryEscape(key) + "&address=10.0.0.2%2F32&reserved="
	imported, err := ImportClientProfiles(link + "1%2C2%2C3#wg")
	if err != nil {
		t.Fatal(err)
	}
	var profile struct {
		Outbounds []struct {
			Settings struct {
				Reserved []byte `json:"reserved"`
			} `json:"settings"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
		t.Fatal(err)
	}
	if got := profile.Outbounds[0].Settings.Reserved; !bytes.Equal(got, []byte{1, 2, 3}) {
		t.Fatalf("reserved %v", got)
	}
	for _, invalid := range []string{"1%2C2", "1%2C2%2C256", "a%2Cb%2Cc"} {
		if _, err := ImportClientProfiles(link + invalid + "#wg"); err == nil {
			t.Errorf("reserved %s imported", invalid)
		}
	}
}

// Mihomo reads the ws Host header in any case and sends it as the TLS SNI;
// a lowercase host left the SNI empty, so a CDN certificate failed.
func TestClashWebSocketHostHeaderGivesSNIInAnyCase(t *testing.T) {
	for _, key := range []string{"Host", "host", "HOST"} {
		imported, err := ImportClientProfiles("proxies:\n - {name: w, type: vless, server: 203.0.113.9, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, network: ws, ws-opts: {path: /p, headers: {" + key + ": cdn.example}}}\n")
		if err != nil {
			t.Fatalf("%s: %v", key, err)
		}
		var profile struct {
			Outbounds []struct {
				StreamSettings struct {
					TLSSettings struct {
						ServerName string `json:"serverName"`
					} `json:"tlsSettings"`
				} `json:"streamSettings"`
			} `json:"outbounds"`
		}
		if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
			t.Fatal(err)
		}
		if got := profile.Outbounds[0].StreamSettings.TLSSettings.ServerName; got != "cdn.example" {
			t.Errorf("headers.%s: serverName = %q, want cdn.example", key, got)
		}
	}
}

// Subscription feeds come as base64 of text that starts with a BOM, and as
// unpadded base64 wrapped into lines; both were rejected whole.
func TestBase64FeedsWithBOMOrWrappedWithoutPadding(t *testing.T) {
	feed := "trojan://pw@h.example:443#one\ntrojan://pw@h.example:8443#two\ntrojan://pw@h.example:9443#three"
	inputs := map[string]string{"bom": base64.StdEncoding.EncodeToString([]byte("\ufeff" + feed))}
	for _, extra := range []string{"", "x", "xx"} { // every length of the last base64 group
		encoded := base64.RawURLEncoding.EncodeToString([]byte(feed + extra))
		var wrapped strings.Builder
		for len(encoded) > 76 {
			wrapped.WriteString(encoded[:76] + "\r\n")
			encoded = encoded[76:]
		}
		inputs["wrapped"+extra] = wrapped.String() + encoded
	}
	for name, input := range inputs {
		result, err := ImportClientProfiles(input)
		if err != nil {
			t.Errorf("%s: %v", name, err)
		} else if len(result.Profiles) != 3 {
			t.Errorf("%s: %d profiles, want 3", name, len(result.Profiles))
		}
	}
}
