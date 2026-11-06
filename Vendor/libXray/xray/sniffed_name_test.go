package xray

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func unusedPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// The app dials an IP and the name is only sniffed for routing. A server outbound must hand the
// server that name, since the server routes by it, also after a loopback into a provider's routing
// (looped.test); a direct outbound must still dial the app's IP.
func TestServerGetsTheSniffedNameWhileDirectKeepsTheIP(t *testing.T) {
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "site") }))
	defer site.Close()
	siteURL, _ := url.Parse(site.URL)
	clientPort, serverPort := unusedPort(t), unusedPort(t)
	// server-in stands in for the remote server: only a request that names the site reaches it.
	instance, err := StartXrayFromJSON(fmt.Sprintf(`{
		"inbounds": [
			{"tag": "client-in", "listen": "127.0.0.1", "port": %d, "protocol": "socks", "settings": {"udp": false},
				"sniffing": {"enabled": true, "destOverride": ["http"], "routeOnly": true}},
			{"tag": "server-in", "listen": "127.0.0.1", "port": %d, "protocol": "socks", "settings": {"udp": false}}],
		"outbounds": [
			{"tag": "server", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": %d}]}},
			{"tag": "direct", "protocol": "freedom"},
			{"tag": "site", "protocol": "freedom", "settings": {"redirect": "%s"}},
			{"tag": "loop", "protocol": "loopback", "settings": {"inboundTag": "provider"}},
			{"tag": "block", "protocol": "blackhole"}],
		"routing": {"rules": [
			{"inboundTag": ["server-in"], "domain": ["full:named.test", "full:looped.test"], "outboundTag": "site"},
			{"inboundTag": ["server-in"], "network": "tcp,udp", "outboundTag": "block"},
			{"inboundTag": ["provider"], "outboundTag": "server"},
			{"domain": ["full:named.test"], "outboundTag": "server"},
			{"domain": ["full:looped.test"], "outboundTag": "loop"},
			{"domain": ["full:direct.test"], "outboundTag": "direct"},
			{"network": "tcp,udp", "outboundTag": "block"}]}}`, clientPort, serverPort, serverPort, siteURL.Host))
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	proxy, _ := url.Parse(fmt.Sprintf("socks5://127.0.0.1:%d", clientPort))
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}}
	for _, host := range []string{"named.test", "looped.test", "direct.test"} {
		request, _ := http.NewRequest("GET", site.URL, nil) // dials the site's IP, names host
		request.Host = host
		response, err := client.Do(request)
		if err != nil {
			t.Fatalf("%s: %v", host, err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || string(body) != "site" {
			t.Fatalf("%s: got %q, %v", host, body, err)
		}
	}
}
