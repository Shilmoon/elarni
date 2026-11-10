package share

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/xtls/xray-core/app/proxyman"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/transport/internet"
	"google.golang.org/protobuf/proto"
)

// Xray JSON keeps its own spelling when it is imported: the vnext and servers lists, REALITY's publicKey and
// the long transport names. "Share" must still write a link that imports again as the same server.
func TestShareLinksOfClassicXrayJSONImportAgain(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	key := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	for _, test := range []struct {
		name, outbound string
		want           []string
	}{
		{"vless vnext with a REALITY publicKey",
			`{"protocol":"vless","settings":{"vnext":[{"address":"203.0.113.7","port":8443,"users":[{"id":"` + id + `","flow":"xtls-rprx-vision","encryption":"none"}]}]},
			  "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"example.com","fingerprint":"chrome","publicKey":"` + key + `","shortId":"0123abcd"}}}`,
			[]string{"vless://" + id + "@203.0.113.7:8443?", "flow=xtls-rprx-vision", "pbk=" + key, "sid=0123abcd"}},
		{"vless vnext over IPv6",
			`{"protocol":"vless","settings":{"vnext":[{"address":"2001:db8::7","port":443,"users":[{"id":"` + id + `","encryption":"none"}]}]},
			  "streamSettings":{"network":"raw","security":"tls","tlsSettings":{"serverName":"example.com"}}}`,
			[]string{"vless://" + id + "@[2001:db8::7]:443?"}},
		{"vmess vnext over websocket",
			`{"protocol":"vmess","settings":{"vnext":[{"address":"vmess.example.com","port":443,"users":[{"id":"` + id + `","security":"aes-128-gcm"}]}]},
			  "streamSettings":{"network":"websocket","security":"tls","tlsSettings":{"serverName":"vmess.example.com"},"wsSettings":{"path":"/socket","host":"cdn.example.com"}}}`,
			[]string{"vmess://" + id + "@vmess.example.com:443?", "encryption=aes-128-gcm", "type=ws", "path=%2Fsocket", "host=cdn.example.com"}},
		{"trojan servers with an HTTP header on tcp",
			`{"protocol":"trojan","settings":{"servers":[{"address":"203.0.113.8","port":443,"password":"secret"}]},
			  "streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"example.com"},
			    "tcpSettings":{"header":{"type":"http","request":{"path":["/video"],"headers":{"Host":["cdn.example.com"]}}}}}}`,
			[]string{"trojan://secret@203.0.113.8:443?", "headerType=http", "path=%2Fvideo", "host=cdn.example.com"}},
		{"shadowsocks servers",
			`{"protocol":"shadowsocks","settings":{"servers":[{"address":"203.0.113.9","port":8388,"method":"aes-256-gcm","password":"secret"}]}}`,
			[]string{"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:secret")) + "@203.0.113.9:8388"}},
		{"socks servers with a user",
			`{"protocol":"socks","settings":{"servers":[{"address":"203.0.113.10","port":1080,"users":[{"user":"name","pass":"secret"}]}]}}`,
			[]string{"socks://" + base64.StdEncoding.EncodeToString([]byte("name:secret")) + "@203.0.113.10:1080"}},
		{"vless over splithttp",
			`{"protocol":"vless","settings":{"address":"203.0.113.11","port":443,"id":"` + id + `","encryption":"none"},
			  "streamSettings":{"network":"splithttp","security":"tls","tlsSettings":{"serverName":"example.com"},
			    "splithttpSettings":{"host":"cdn.example.com","path":"/x","mode":"packet-up"}}}`,
			[]string{"type=xhttp", "host=cdn.example.com", "path=%2Fx", "mode=packet-up"}},
		{"vless over mkcp",
			`{"protocol":"vless","settings":{"address":"10.0.0.12","port":443,"id":"` + id + `","encryption":"none"},
			  "streamSettings":{"network":"mkcp","kcpSettings":{"seed":"fixture-seed"}}}`,
			[]string{"type=kcp", "seed=fixture-seed"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			imported, err := ImportClientProfiles(`{"outbounds":[` + test.outbound + `]}`)
			if err != nil {
				t.Fatal(err)
			}
			links, err := ConvertXrayJsonToShareLinks(imported.Profiles[0].Config)
			if err != nil {
				t.Fatal(err)
			}
			for _, part := range test.want {
				if !strings.Contains(links, part) {
					t.Errorf("link lacks %q: %s", part, links)
				}
			}
			again, err := ImportClientProfiles(links)
			if err != nil {
				t.Fatalf("the exported link does not import: %v\n%s", err, links)
			}
			want, got := builtOutbound(t, imported.Profiles[0].Config), builtOutbound(t, again.Profiles[0].Config)
			if !proto.Equal(want.proxy, got.proxy) {
				t.Errorf("server changed:\n%v\nwas\n%v\nlink %s", got.proxy, want.proxy, links)
			}
			if !proto.Equal(want.stream, got.stream) {
				t.Errorf("transport changed:\n%v\nwas\n%v\nlink %s", got.stream, want.stream, links)
			}
		})
	}
}

// An outbound without a server writes no link rather than one to "<nil>:0".
func TestShareLinksSkipAnOutboundWithoutAServer(t *testing.T) {
	for _, outbound := range []string{
		`{"protocol":"vless","settings":{"vnext":[]}}`,
		`{"protocol":"vless","settings":{"vnext":[{"address":"203.0.113.7","port":443,"users":[]}]}}`,
		`{"protocol":"vmess","settings":{}}`,
		`{"protocol":"trojan","settings":{"servers":[{"port":443,"password":"secret"}]}}`,
		`{"protocol":"shadowsocks","settings":{"servers":[]}}`,
		`{"protocol":"socks","settings":{}}`,
		`{"protocol":"hysteria","settings":{"version":2}}`,
	} {
		links, err := ConvertXrayJsonToShareLinks([]byte(`{"outbounds":[` + outbound + `]}`))
		if err == nil {
			t.Errorf("%s exported %q", outbound, links)
		}
	}
}

type builtEndpoint struct{ proxy, stream proto.Message }

func builtOutbound(t *testing.T, raw []byte) builtEndpoint {
	t.Helper()
	var profile conf.Config
	if err := json.Unmarshal(raw, &profile); err != nil {
		t.Fatal(err)
	}
	restoreNilRawMessages(reflect.ValueOf(&profile))
	built, err := profile.OutboundConfigs[0].Build()
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := built.ProxySettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	sender, err := built.SenderSettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	stream := sender.(*proxyman.SenderConfig).StreamSettings
	if stream == nil {
		// A link always names its transport; no stream settings mean plain TCP.
		stream = &internet.StreamConfig{ProtocolName: "tcp"}
	}
	return builtEndpoint{proxy, stream}
}
