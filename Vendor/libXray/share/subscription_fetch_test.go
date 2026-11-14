package share

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// socksFixture accepts user:pass and records each IPv4 CONNECT target.
func socksFixture(t *testing.T, targets chan<- string) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				buffer := make([]byte, 256)
				if _, err := io.ReadFull(conn, buffer[:2]); err != nil {
					return
				}
				if _, err := io.ReadFull(conn, buffer[:buffer[1]]); err != nil {
					return
				}
				_, _ = conn.Write([]byte{5, 2})
				field := func() string {
					if _, err := io.ReadFull(conn, buffer[:1]); err != nil {
						return ""
					}
					value := make([]byte, buffer[0])
					_, _ = io.ReadFull(conn, value)
					return string(value)
				}
				_, _ = io.ReadFull(conn, buffer[:1])
				if field()+":"+field() != "user:pass" {
					_, _ = conn.Write([]byte{1, 1})
					return
				}
				_, _ = conn.Write([]byte{1, 0})
				if _, err := io.ReadFull(conn, buffer[:10]); err != nil || buffer[3] != 1 {
					return
				}
				target := net.JoinHostPort(net.IP(buffer[4:8]).String(), strconv.Itoa(int(binary.BigEndian.Uint16(buffer[8:10]))))
				targets <- target
				upstream, err := net.Dial("tcp", target)
				if err != nil {
					return
				}
				defer upstream.Close()
				_, _ = conn.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
				go func() { _, _ = io.Copy(upstream, conn) }()
				_, _ = io.Copy(conn, upstream)
			}()
		}
	}()
	return listener.Addr().String()
}

// dotFixture is a DNS-over-TLS server that answers feed.test with answer. Its
// certificate names 127.0.0.1 and 1.1.1.1, so it can stand in for tunnelDNS.
func dotFixture(t *testing.T, answer netip.Addr) (string, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1), net.IPv4(1, 1, 1, 1)},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)
	dnsServer, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}})
	if err != nil {
		t.Fatal(err)
	}
	serveDNSFixture(t, dnsServer, answer)
	return dnsServer.Addr().String(), roots
}

// plainDNSFixture is dotFixture without TLS.
func plainDNSFixture(t *testing.T, answer netip.Addr) string {
	t.Helper()
	dnsServer, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	serveDNSFixture(t, dnsServer, answer)
	return dnsServer.Addr().String()
}

// serveDNSFixture answers feed.test with answer over DNS-over-TCP framing.
func serveDNSFixture(t *testing.T, dnsServer net.Listener, answer netip.Addr) {
	t.Cleanup(func() { _ = dnsServer.Close() })
	go func() {
		for {
			conn, err := dnsServer.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				for {
					var size [2]byte
					if _, err := io.ReadFull(conn, size[:]); err != nil {
						return
					}
					query := make([]byte, binary.BigEndian.Uint16(size[:]))
					if _, err := io.ReadFull(conn, query); err != nil {
						return
					}
					var message dnsmessage.Message
					if message.Unpack(query) != nil || len(message.Questions) != 1 {
						return
					}
					question := message.Questions[0]
					message.Header.Response = true
					if question.Name.String() == "feed.test." && question.Type == dnsmessage.TypeA {
						message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
							Body: &dnsmessage.AResource{A: answer.As4()}}}
					}
					reply, err := message.Pack()
					if err != nil {
						return
					}
					_, _ = conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(reply))), reply...))
				}
			}()
		}
	}()
}

// With FakeDNS on, the core answers every port-53 query from its listeners from the
// 198.18.0.0/15 pool, which a fetch refuses as private, so a proxied lookup must not
// be one: geofiles and subscriptions then failed while connected.
func TestProxiedLookupIsNotAnsweredByFakeDNS(t *testing.T) {
	dot, roots := dotFixture(t, netip.MustParseAddr("192.0.2.7"))
	previous := tunnelDNSRoots
	tunnelDNSRoots = roots
	t.Cleanup(func() { tunnelDNSRoots = previous })
	port := trafficPort(t)
	startTrafficCore(t, map[string]any{
		"inbounds": []any{map[string]any{"tag": "elarni-socks", "listen": "127.0.0.1", "port": port, "protocol": "socks",
			"settings": map[string]any{"auth": "password", "accounts": []any{map[string]any{"user": "user", "pass": "pass"}}}}},
		// The proxy outbound stands in for the server: it takes every connection to the fixture.
		"outbounds": []any{
			map[string]any{"tag": "proxy", "protocol": "freedom", "settings": map[string]any{"redirect": dot}},
			map[string]any{"tag": "elarni-dns", "protocol": "dns"},
		},
		"dns":     map[string]any{"servers": []any{"fakedns"}},
		"fakedns": []any{map[string]any{"ipPool": "198.18.0.0/15", "poolSize": 65535}},
		// The first rule as compile_owned_config writes it.
		"routing": map[string]any{"rules": []any{
			map[string]any{"type": "field", "network": "tcp,udp", "port": 53, "inboundTag": []any{"elarni-socks"}, "outboundTag": "elarni-dns"},
			map[string]any{"type": "field", "network": "tcp,udp", "outboundTag": "proxy"},
		}},
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addresses, err := tunnelResolver("socks5://user:pass@127.0.0.1:"+strconv.Itoa(port)).LookupNetIP(ctx, "ip4", "feed.test")
	if err != nil || len(addresses) != 1 || addresses[0] != netip.MustParseAddr("192.0.2.7") {
		t.Fatalf("lookup through the core: %v %v", addresses, err)
	}
}

// Where DNS over TLS can't get through (a network or a profile rule that blocks it), the
// plain query still reaches the core's own DNS, which answers it unless FakeDNS is on.
func TestProxiedLookupFallsBackToPlainDNS(t *testing.T) {
	plain := plainDNSFixture(t, netip.MustParseAddr("192.0.2.7"))
	previous, previousPlain := tunnelDNS, tunnelPlainDNS
	tunnelDNS, tunnelPlainDNS = "127.0.0.1:1", plain
	t.Cleanup(func() { tunnelDNS, tunnelPlainDNS = previous, previousPlain })
	targets := make(chan string, 32)
	proxy := "socks5://user:pass@" + socksFixture(t, targets)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addresses, err := tunnelLookup(proxy)(ctx, "ip4", "feed.test")
	if err != nil || len(addresses) != 1 || addresses[0] != netip.MustParseAddr("192.0.2.7") {
		t.Fatalf("lookup through the proxy: %v %v", addresses, err)
	}
}

// While a VPN with FakeDNS carries the app's own traffic (Apple, the desktop TUN), the
// system resolver answers from its pool: a fetch asked to approve a private address.
func TestFakeDNSAnswersAreLookedUpAgain(t *testing.T) {
	fake, fakeRoots := dotFixture(t, netip.MustParseAddr("198.18.0.5"))
	real, roots := dotFixture(t, netip.MustParseAddr("192.0.2.7"))
	system := func(address string, roots *x509.CertPool) *net.Resolver {
		return &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&tls.Dialer{Config: &tls.Config{RootCAs: roots, ServerName: "127.0.0.1"}}).DialContext(ctx, "tcp", address)
		}}
	}
	previous, previousDNS, previousRoots := net.DefaultResolver, tunnelDNS, tunnelDNSRoots
	t.Cleanup(func() { net.DefaultResolver, tunnelDNS, tunnelDNSRoots = previous, previousDNS, previousRoots })
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	lookup := func(want string) {
		t.Helper()
		addresses, err := systemLookup(ctx, "ip4", "feed.test")
		if err != nil || len(addresses) != 1 || addresses[0] != netip.MustParseAddr(want) {
			t.Fatalf("lookup: %v %v, want %s", addresses, err, want)
		}
	}
	net.DefaultResolver, tunnelDNS, tunnelDNSRoots = system(fake, fakeRoots), real, roots
	lookup("192.0.2.7")
	// Without a reachable resolver the placeholder stays, so approving it still works through the VPN.
	tunnelDNS = "127.0.0.1:1"
	lookup("198.18.0.5")
	// A real answer is used as it is.
	net.DefaultResolver = system(real, roots)
	lookup("192.0.2.7")
}

// Android keeps the app's own sockets out of its VPN, so a proxied fetch must not
// ask the system resolver: the feed's hostname would leave the tunnel.
func TestProxiedFetchResolvesThroughTheProxy(t *testing.T) {
	dnsServer, roots := dotFixture(t, netip.MustParseAddr("192.0.2.7"))
	previous, previousRoots := tunnelDNS, tunnelDNSRoots
	tunnelDNS, tunnelDNSRoots = dnsServer, roots
	t.Cleanup(func() { tunnelDNS, tunnelDNSRoots = previous, previousRoots })
	targets := make(chan string, 32)
	proxy := "socks5://user:pass@" + socksFixture(t, targets)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addresses, err := tunnelResolver(proxy).LookupNetIP(ctx, "ip4", "feed.test")
	if err != nil || len(addresses) != 1 || addresses[0] != netip.MustParseAddr("192.0.2.7") {
		t.Fatalf("lookup through the proxy failed: %v %v", addresses, err)
	}
	if target := <-targets; target != dnsServer {
		t.Fatalf("the lookup did not go through the proxy: %s", target)
	}
}

func TestFetchThroughLocalSocksDialsOnlyEvaluatedAddresses(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		_, _ = w.Write([]byte("via core"))
	}))
	defer server.Close()
	targets := make(chan string, 4)
	proxy := "socks5://user:pass@" + socksFixture(t, targets)
	resolve := func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		address, err := netip.ParseAddr(host)
		return []netip.Addr{address}, err
	}
	feed := server.URL + "/feed"
	request := SubscriptionFetchRequest{URL: feed, Proxy: proxy, ApprovedChain: []string{approvalFingerprint(feed, []string{"cleartext_http", "loopback_target"})}}
	value, err := fetchFeedUsing(request, resolve, func() *http.Transport { return &http.Transport{} })
	if err != nil || value.(map[string]any)["body"] != "via core" {
		t.Fatalf("fetch through the core failed: %v %v", value, err)
	}
	if target := <-targets; target != server.Listener.Addr().String() {
		t.Fatalf("proxy dialed %s, not the evaluated address", target)
	}
	// Only the running core's loopback SOCKS inbound is accepted.
	for _, invalid := range []string{"socks5://192.0.2.1:1080", "http://127.0.0.1:1080", "socks5://localhost:1080", "socks5://127.0.0.1"} {
		request.Proxy = invalid
		if _, err := fetchFeedUsing(request, resolve, func() *http.Transport { return &http.Transport{} }); err == nil || err.Error() != "invalid_fetch_options" {
			t.Fatalf("%s accepted: %v", invalid, err)
		}
	}
	// A stopped core fails the fetch instead of falling back to a direct connection.
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	request.Proxy = "socks5://" + closed.Addr().String()
	_ = closed.Close()
	if _, err := fetchFeedUsing(request, resolve, func() *http.Transport { return &http.Transport{} }); err == nil || requests != 1 {
		t.Fatalf("fetch bypassed the stopped proxy: %v, %d requests", err, requests)
	}
}

func TestSubscriptionFrontingVerifiesTLSAndBindsApproval(t *testing.T) {
	var sent string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS.ServerName != "example.com" || r.Host != "provider.invalid" || r.URL.RequestURI() != "/feed?token=a%2Bb" {
			t.Error("fronting changed TLS identity, HTTP authority or token")
		}
		identity, _ := url.Parse("https://provider.invalid")
		if r.Header.Get("X-HWID") != deviceID("installation", "", identity) {
			t.Error("HWID not scoped to HTTP recipient")
		}
		sent = r.Header.Get("X-HWID")
		_, _ = w.Write([]byte("fronted"))
	}))
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport := func() *http.Transport { return &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}} }
	_, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	request := SubscriptionFetchRequest{URL: "https://example.com:" + port + "/feed?token=a%2Bb",
		ConnectAddress: "127.0.0.1", HTTPHost: "provider.invalid", InstallationID: "installation",
		FragmentLength: "80-250", FragmentInterval: "0"}
	resolve := func(ctx context.Context, network, host string) ([]netip.Addr, error) {
		if host != "127.0.0.1" {
			t.Error("connect override was not resolved")
		}
		return net.DefaultResolver.LookupNetIP(ctx, network, host)
	}
	result, err := fetchFeedUsing(request, resolve, transport)
	if err != nil {
		t.Fatal(err)
	}
	request.ApprovedChain = result.(map[string]any)["warning"].(map[string]any)["chain"].([]string)
	result, err = fetchFeedUsing(request, resolve, transport)
	if shown, _ := SubscriptionDeviceID(request); shown != sent {
		t.Fatal("the shown device ID is not the fronted fetch's")
	}
	if err != nil || result.(map[string]any)["body"] != "fronted" {
		t.Fatal("fronted TLS failed", err)
	}
	request.HTTPHost = "changed.invalid"
	result, err = fetchFeedUsing(request, resolve, transport)
	if err != nil || result.(map[string]any)["warning"] == nil {
		t.Fatal("HTTP authority change reused approval")
	}
	request.URL = "https://wrong.invalid:" + port + "/feed?token=a%2Bb"
	request.HTTPHost = "provider.invalid"
	result, err = fetchFeedUsing(request, resolve, transport)
	if err != nil {
		t.Fatal(err)
	}
	request.ApprovedChain = result.(map[string]any)["warning"].(map[string]any)["chain"].([]string)
	if _, err = fetchFeedUsing(request, resolve, transport); err == nil {
		t.Fatal("fronting disabled TLS verification")
	}
}

func TestTLSHelloFragmentationPreservesBytesAndCancelsDelay(t *testing.T) {
	writer, reader := net.Pipe()
	defer writer.Close()
	defer reader.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn := &fragmentHelloConn{Conn: writer, ctx: ctx, length: [2]int{3, 3}, interval: [2]int{1000, 1000}}
	data := []byte{22, 3, 1, 0, 4, 1, 2, 3, 4}
	done := make(chan error, 1)
	go func() {
		n, err := conn.Write(data)
		if n != 3 {
			t.Errorf("partial write count = %d", n)
		}
		done <- err
	}()
	first := make([]byte, 3)
	if _, err := io.ReadFull(reader, first); err != nil || string(first) != string(data[:3]) {
		t.Fatal("fragment corrupted", err)
	}
	cancel()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatal("cancellation lost", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation waited for fragment interval")
	}
}

func TestSubscriptionFallbackKeepsTokenAndRequiresOrderedApproval(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.RequestURI() != "/feed?token=a%2Bb" {
			t.Error("fallback changed path or token")
		}
		_, _ = w.Write([]byte("fixture"))
	}))
	defer server.Close()
	request := SubscriptionFetchRequest{URL: strings.Replace(server.URL, "127.0.0.1", "127.0.0.2", 1) + "/feed?token=a%2Bb", FallbackHosts: []string{"127.0.0.1"}}
	for expected := 1; expected <= 2; expected++ {
		result, err := FetchSubscription(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		warning, ok := result.(map[string]any)["warning"].(map[string]any)
		if !ok || requests != 0 {
			t.Fatal("fallback fetched before approval")
		}
		request.ApprovedChain = warning["chain"].([]string)
		if len(request.ApprovedChain) != expected {
			t.Fatal("fallback approval did not retain failed primary")
		}
	}
	result, err := FetchSubscription(context.Background(), request)
	if err != nil || result.(map[string]any)["body"] != "fixture" || requests != 1 {
		t.Fatal("approved fallback failed", err)
	}
}

func TestSubscriptionFallbackStopsForRemovedSubscriptions(t *testing.T) {
	for _, status := range []int{404, 410} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(status) }))
		request := SubscriptionFetchRequest{URL: server.URL, FallbackHosts: []string{"127.0.0.2"},
			ApprovedChain: []string{approvalFingerprint(server.URL, []string{"cleartext_http", "loopback_target"})}}
		lookups := 0
		resolver := func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			lookups++
			return net.DefaultResolver.LookupNetIP(ctx, network, host)
		}
		_, err := fetchFeedUsing(request, resolver, func() *http.Transport { return &http.Transport{} })
		server.Close()
		if err == nil || err.Error() != "subscription_unavailable" || lookups != 1 {
			t.Fatalf("HTTP %d attempted fallback: %v, lookups=%d", status, err, lookups)
		}
	}
}

func TestFetchAddressPolicy(t *testing.T) {
	for address, want := range map[string]string{
		"8.8.8.8": "", "2606:4700:4700::1111": "",
		"127.0.0.1": "loopback_target", "::ffff:127.0.0.1": "loopback_target", "64:ff9b::7f00:1": "loopback_target",
		"192.168.1.1": "private_target", "100.64.0.1": "private_target", "2001:db8::1": "private_target", "3fff::1": "private_target",
		"100:0:0:1::1": "private_target", "100:0:0:1:ffff:ffff:ffff:ffff": "private_target",
	} {
		if got := addressRisk(netip.MustParseAddr(address)); got != want {
			t.Errorf("%s classified %q, want %q", address, got, want)
		}
	}
	for _, target := range []string{"https://user:secret@example.com/", "file:///private", "https://example.com/#fragment"} {
		if _, err := feedTarget(target); err == nil {
			t.Error("unsafe source target accepted")
		}
	}
}

// A subscription served over http from a domain name goes through the approval an http address
// needs: every cleartext hop, a redirect too, carries the cleartext_http risk.
func TestHTTPSubscriptionOnADomainIsApprovedHopByHop(t *testing.T) {
	var port string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/old" {
			http.Redirect(w, r, "http://next.example:"+port+"/new", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte("cleartext feed"))
	}))
	defer server.Close()
	_, port, _ = net.SplitHostPort(server.Listener.Addr().String())
	resolve := func(context.Context, string, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
	}
	transport := func() *http.Transport { return &http.Transport{} }
	request := SubscriptionFetchRequest{URL: "http://feed.example:" + port + "/old", InstallationID: "installation"}
	if _, err := SubscriptionDeviceID(request); err != nil {
		t.Fatal(err)
	}
	for hops := 1; hops <= 2; hops++ {
		value, err := fetchFeedUsing(request, resolve, transport)
		if err != nil {
			t.Fatalf("hop %d: %v", hops, err)
		}
		warning, ok := value.(map[string]any)["warning"].(map[string]any)
		if !ok || !slices.Equal(warning["riskCodes"].([]string), []string{"cleartext_http", "loopback_target"}) || len(warning["chain"].([]string)) != hops {
			t.Fatalf("hop %d: %v", hops, value)
		}
		request.ApprovedChain = warning["chain"].([]string)
	}
	value, err := fetchFeedUsing(request, resolve, transport)
	if err != nil || value.(map[string]any)["body"] != "cleartext feed" {
		t.Fatalf("approved http feed: %v %v", value, err)
	}
}

// Remnawave answers a device over its limit with HTTP 200, an empty body and a header saying why.
func TestDeviceLimitOnAnEmptySuccessfulResponse(t *testing.T) {
	for _, test := range []struct {
		header, value, body, want string
	}{
		{"X-Hwid-Limit", "true", "", "hwid_limit"},
		{"X-Hwid-Max-Devices-Reached", "TRUE", " \r\n\t", "hwid_limit"},
		{"X-Hwid-Not-Supported", "true", "\n", "hwid_required"},
		{"X-Hwid-Limit", "true", "trojan://pw@127.0.0.1:443#kept", ""},
		{"X-Hwid-Limit", "false", "", ""},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set(test.header, test.value)
			_, _ = w.Write([]byte(test.body))
		}))
		request := SubscriptionFetchRequest{URL: server.URL, ApprovedChain: loopbackApprovals(server.URL)}
		value, err := fetchFeedUsing(request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} })
		if test.want != "" {
			if err == nil || err.Error() != test.want {
				t.Errorf("%s: %v, %v; want %s", test.header, value, err, test.want)
			}
		} else if err != nil || value.(map[string]any)["body"] != test.body {
			t.Errorf("%s with body %q: %v, %v", test.header, test.body, value, err)
		}
		server.Close()
	}
}

func TestFetchRequiresEveryRiskyRedirectApprovalAndScopesHWID(t *testing.T) {
	firstCalls, secondCalls := 0, 0
	var firstID, secondID string
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondCalls++
		secondID = r.Header.Get("X-HWID")
		w.Header().Set("Profile-Update-Interval", "2")
		w.Header().Set("Hide-Url", "")
		_, _ = w.Write([]byte("synthetic subscription"))
	}))
	defer second.Close()
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		firstCalls++
		firstID = r.Header.Get("X-HWID")
		http.Redirect(w, r, second.URL+"/feed", http.StatusFound)
	}))
	defer first.Close()
	request := SubscriptionFetchRequest{URL: first.URL + "/feed", InstallationID: "synthetic-installation-id"}
	for approved := 0; approved < 2; approved++ {
		value, err := FetchSubscription(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		warning, ok := value.(map[string]any)["warning"].(map[string]any)
		if !ok {
			t.Fatal("risky destination reached without approval")
		}
		request.ApprovedChain = warning["chain"].([]string)
		if len(request.ApprovedChain) != approved+1 || secondCalls != 0 || (approved == 0 && firstCalls != 0) {
			t.Fatal("approval did not precede network access")
		}
	}
	value, err := FetchSubscription(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	result := value.(map[string]any)
	if _, present := result["headers"].(map[string]string)["hide-url"]; !present {
		t.Fatal("explicit empty hide-url header lost its precedence")
	}
	if result["body"] != "synthetic subscription" || result["headers"].(map[string]string)["profile-update-interval"] != "2" {
		t.Fatal("feed or metadata lost")
	}
	if firstID == "" || secondID == "" || firstID == secondID {
		t.Fatal("HWID not scoped to origin")
	}
}

// RFC 9110 allows a fragment in Location; it never reaches the server.
func TestFetchDropsTheFragmentOfARedirect(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/feed" {
			w.Header().Set("Location", "/ok#name")
			w.WriteHeader(http.StatusFound)
			return
		}
		_, _ = w.Write([]byte("synthetic subscription"))
	}))
	defer server.Close()
	request := SubscriptionFetchRequest{URL: server.URL + "/feed"}
	for range 3 {
		value, err := FetchSubscription(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		result := value.(map[string]any)
		if warning, ok := result["warning"].(map[string]any); ok {
			request.ApprovedChain = warning["chain"].([]string)
			continue
		}
		if result["body"] != "synthetic subscription" {
			t.Fatalf("feed lost: %v", result)
		}
		return
	}
	t.Fatal("approvals never settled")
}

func TestFetchPinsDNSAndVerifiesOriginalTLSHostname(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"elarni.invalid"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS.ServerName != "elarni.invalid" || !strings.HasPrefix(r.Host, "elarni.invalid:") {
			t.Error("original hostname lost")
		}
		_, _ = w.Write([]byte("pinned TLS"))
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	server.StartTLS()
	defer server.Close()
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)
	newTransport := func() *http.Transport { return &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}} }
	_, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	resolutions := 0
	resolve := func(context.Context, string, string) ([]netip.Addr, error) {
		resolutions++
		if resolutions > 1 {
			return []netip.Addr{netip.MustParseAddr("192.0.2.1")}, nil
		}
		return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
	}
	request := SubscriptionFetchRequest{URL: "https://elarni.invalid:" + port + "/feed"}
	value, err := fetchFeedUsing(request, resolve, newTransport)
	if err != nil {
		t.Fatal(err)
	}
	request.ApprovedChain = value.(map[string]any)["warning"].(map[string]any)["chain"].([]string)
	resolutions = 0
	value, err = fetchFeedUsing(request, resolve, newTransport)
	if err != nil || resolutions != 1 || value.(map[string]any)["body"] != "pinned TLS" {
		t.Fatalf("address pinning/TLS failed: %v", err)
	}
	request.URL = "https://wrong.invalid:" + port + "/feed"
	request.ApprovedChain = []string{approvalFingerprint(request.URL, []string{"loopback_target"})}
	resolutions = 0
	if _, err := fetchFeedUsing(request, resolve, newTransport); err == nil {
		t.Fatal("TLS hostname mismatch was accepted")
	}
}

// The test seam: a controlled resolver and trust roots instead of the system ones.
func fetchFeedUsing(request SubscriptionFetchRequest, resolve func(context.Context, string, string) ([]netip.Addr, error), newTransport func() *http.Transport) (any, error) {
	return fetchResourceUsing(context.Background(), request, resolve, newTransport, 4*1024*1024, 30*time.Second, false, "")
}

// A geofile downloads again only when the server says it changed.
func TestFetchSendsStoredValidatorsAndReportsAnUnchangedFile(t *testing.T) {
	const tag, modified = `"geo-v1"`, "Wed, 28 Oct 2026 10:00:00 GMT"
	bodies := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", tag)
		w.Header().Set("Last-Modified", modified)
		if r.Header.Get("If-None-Match") == tag || r.Header.Get("If-Modified-Since") == modified {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		bodies++
		_, _ = w.Write([]byte("geodata"))
	}))
	defer server.Close()
	fetch := func(payload string) (map[string]any, error) {
		var request SubscriptionFetchRequest
		if err := json.Unmarshal([]byte(payload), &request); err != nil {
			t.Fatal(err)
		}
		request.URL, request.ApprovedChain = server.URL, loopbackApprovals(server.URL)
		result, err := fetchResourceUsing(context.Background(), request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} }, 1024, 5*time.Second, true, "")
		value, _ := result.(map[string]any)
		return value, err
	}
	first, err := fetch(`{}`)
	if err != nil || string(first["body"].([]byte)) != "geodata" || first["etag"] != tag || first["lastModified"] != modified {
		t.Fatalf("first download: %v %v", first, err)
	}
	for _, payload := range []string{`{"etag":` + strconv.Quote(tag) + `}`, `{"lastModified":` + strconv.Quote(modified) + `}`} {
		again, err := fetch(payload)
		if err != nil || again["notModified"] != true || again["body"] != nil || bodies != 1 {
			t.Fatalf("%s: %v %v after %d bodies", payload, again, err, bodies)
		}
	}
	if _, err := fetch(`{"etag":"\"v1\"\r\nX-Injected: 1"}`); err == nil || err.Error() != "invalid_fetch_options" {
		t.Fatal("a stored validator with a line break reached the request:", err)
	}
}

func loopbackApprovals(urls ...string) []string {
	chain := []string{}
	for _, target := range urls {
		chain = append(chain, approvalFingerprint(target, []string{"cleartext_http", "loopback_target"}))
	}
	return chain
}

// A mirror of the same panel must count as the same device.
func TestSubscriptionFallbackSendsTheSubscriptionDeviceID(t *testing.T) {
	var got string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("X-HWID")
		_, _ = w.Write([]byte("fixture"))
	}))
	defer server.Close()
	primary := strings.Replace(server.URL, "127.0.0.1", "127.0.0.2", 1) + "/feed"
	request := SubscriptionFetchRequest{URL: primary, FallbackHosts: []string{"127.0.0.1"}, InstallationID: "installation",
		ApprovedChain: loopbackApprovals(primary, server.URL+"/feed")}
	result, err := fetchFeedUsing(request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} })
	if err != nil || result.(map[string]any)["body"] != "fixture" {
		t.Fatal("fallback fetch failed", err, result)
	}
	identity, _ := url.Parse(primary)
	if got != deviceID("installation", "", identity) {
		t.Fatal("fallback host sent a different HWID")
	}
}

// The device ID a subscription shows is the X-HWID its fetch sends. A reset salt
// changes only that subscription's ID, and no salt keeps the ID an install had.
func TestSubscriptionDeviceIDIsTheHeaderSentAndResetsPerSubscription(t *testing.T) {
	var got string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("X-HWID")
		_, _ = w.Write([]byte("fixture"))
	}))
	defer server.Close()
	target := server.URL + "/feed?token=a"
	request := SubscriptionFetchRequest{URL: target, InstallationID: "installation", ApprovedChain: loopbackApprovals(target)}
	before := hmac.New(sha256.New, []byte("installation"))
	_, _ = io.WriteString(before, server.URL)
	seen := map[string]string{}
	for _, salt := range []string{"", "first", "second"} {
		request.DeviceSalt = salt
		if _, err := fetchFeedUsing(request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} }); err != nil {
			t.Fatal(err)
		}
		shown, err := SubscriptionDeviceID(request)
		if err != nil || shown != got {
			t.Fatalf("salt %q: shown %q, sent %q, %v", salt, shown, got, err)
		}
		seen[salt] = shown
	}
	if seen[""] != hex.EncodeToString(before.Sum(nil)) {
		t.Fatal("a subscription that was never reset changed its device ID")
	}
	if seen[""] == seen["first"] || seen["first"] == seen["second"] || seen[""] == seen["second"] {
		t.Fatal("a reset did not give the subscription a new device ID")
	}
	other := request
	other.URL, other.DeviceSalt = "https://other.example/feed", ""
	if shown, _ := SubscriptionDeviceID(other); shown == seen[""] || shown == "" {
		t.Fatal("two providers saw one device ID")
	}
	for _, invalid := range []SubscriptionFetchRequest{{URL: "ftp://provider.example/feed", InstallationID: "installation"}, {URL: target}} {
		if _, err := SubscriptionDeviceID(invalid); err == nil {
			t.Fatalf("%+v accepted", invalid)
		}
	}
}

// After the main URL and its mirrors fail, the provider's fallback-url gets its turn.
func TestSubscriptionFallbackURLTakesOverAFailingMainURL(t *testing.T) {
	backup := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RequestURI() != "/backup?token=b" {
			t.Error("fallback URL lost its path or token")
		}
		w.Header().Set("Fallback-Url", "https://next.example/feed")
		_, _ = w.Write([]byte("backup fixture"))
	}))
	defer backup.Close()
	for _, failing := range []http.HandlerFunc{
		func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) },
		func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(403) },
	} {
		main := httptest.NewServer(failing)
		feed, fallback := main.URL+"/feed", backup.URL+"/backup?token=b"
		request := SubscriptionFetchRequest{URL: feed, FallbackURL: fallback, ApprovedChain: loopbackApprovals(feed, fallback)}
		result, err := fetchFeedUsing(request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} })
		main.Close()
		if err != nil || result.(map[string]any)["body"] != "backup fixture" {
			t.Fatal("the fallback URL did not take over", err, result)
		}
		if result.(map[string]any)["headers"].(map[string]string)["fallback-url"] != "https://next.example/feed" {
			t.Fatal("the provider's next fallback URL was not passed on", result)
		}
	}
	// A removed subscription stays removed; an unusable stored fallback is skipped, not fatal.
	removed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(404) }))
	defer removed.Close()
	for _, fallback := range []string{backup.URL + "/backup?token=b", "https://user:secret@backup.example/feed"} {
		request := SubscriptionFetchRequest{URL: removed.URL, FallbackURL: fallback, ApprovedChain: loopbackApprovals(removed.URL, fallback)}
		if _, err := fetchFeedUsing(request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} }); err == nil || err.Error() != "subscription_unavailable" {
			t.Fatalf("fallback %q after HTTP 404: %v", fallback, err)
		}
	}
}

// The connect address and HTTP Host are set for the subscription's own host. A mirror and the provider's
// fallback URL are other hosts: they are dialled and addressed as they are named, so they still work when
// the override address does not.
func TestSubscriptionHostOverridesStayWithTheSubscriptionHost(t *testing.T) {
	var hosts []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hosts = append(hosts, r.Host)
		_, _ = w.Write([]byte("fixture"))
	}))
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport := func() *http.Transport { return &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}} }
	_, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	var resolved []string
	resolve := func(_ context.Context, _, host string) ([]netip.Addr, error) {
		resolved = append(resolved, host)
		if host == "blocked.invalid" {
			return nil, errors.New("no such host")
		}
		return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
	}
	primary := "https://subscription.invalid:" + port + "/feed"
	for name, request := range map[string]SubscriptionFetchRequest{
		"mirror":       {URL: primary, FallbackHosts: []string{"example.com"}},
		"fallback URL": {URL: primary, FallbackURL: "https://example.com:" + port + "/feed"},
	} {
		request.ConnectAddress, request.HTTPHost = "blocked.invalid", "front.invalid"
		hosts, resolved = nil, nil
		result, err := fetchFeedUsing(request, resolve, transport)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		request.ApprovedChain = result.(map[string]any)["warning"].(map[string]any)["chain"].([]string)
		result, err = fetchFeedUsing(request, resolve, transport)
		if err != nil || result.(map[string]any)["body"] != "fixture" {
			t.Fatalf("%s did not take over from the unreachable connect address: %v, %v", name, err, result)
		}
		if !slices.Equal(hosts, []string{"example.com:" + port}) {
			t.Fatalf("%s was sent Host %v", name, hosts)
		}
		if !slices.Contains(resolved, "blocked.invalid") || !slices.Contains(resolved, "example.com") {
			t.Fatalf("%s resolved %v", name, resolved)
		}
	}
}

// The last host may use what is left of the fetch budget.
func TestSubscriptionFallbackLastHostGetsTheRemainingTime(t *testing.T) {
	previous := fallbackAttemptLimit
	fallbackAttemptLimit = 100 * time.Millisecond
	t.Cleanup(func() { fallbackAttemptLimit = previous })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(300 * time.Millisecond)
		_, _ = w.Write([]byte("slow fixture"))
	}))
	defer server.Close()
	primary := strings.Replace(server.URL, "127.0.0.1", "127.0.0.2", 1) + "/feed"
	request := SubscriptionFetchRequest{URL: primary, FallbackHosts: []string{"127.0.0.1"},
		ApprovedChain: loopbackApprovals(primary, server.URL+"/feed")}
	result, err := fetchResourceUsing(context.Background(), request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} }, 4*1024*1024, 5*time.Second, false, "")
	if err != nil || result.(map[string]any)["body"] != "slow fixture" {
		t.Fatal("the last host was cut short", err)
	}
}

func TestCancelledDownloadReportsCancelled(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("partial"))
		w.(http.Flusher).Flush()
		close(started)
		<-release
	}))
	defer server.Close()
	defer close(release)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { <-started; cancel() }()
	request := SubscriptionFetchRequest{URL: server.URL + "/feed", ApprovedChain: loopbackApprovals(server.URL + "/feed")}
	_, err := fetchResourceUsing(ctx, request, net.DefaultResolver.LookupNetIP, func() *http.Transport { return &http.Transport{} }, 4*1024*1024, 5*time.Second, false, "")
	if err == nil || err.Error() != "fetch_cancelled" {
		t.Fatalf("cancelled download reported %v", err)
	}
}

// Each failure names its cause, so the app can say whose fault it is.
func TestFetchFailuresNameTheirCause(t *testing.T) {
	var status atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.Host, "127.0.0.3:") {
			_, _ = w.Write([]byte("mirror"))
			return
		}
		w.WriteHeader(int(status.Load()))
	}))
	defer server.Close()
	_, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	feed, mirror := "http://127.0.0.2:"+port+"/feed", "http://127.0.0.3:"+port+"/feed"
	loopback := func(context.Context, string, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
	}
	transport := func() *http.Transport { return &http.Transport{} }
	for code, want := range map[int]string{401: "subscription_denied", 403: "subscription_denied", 429: "rate_limited",
		500: "provider_error", 502: "provider_error", 503: "provider_error", 418: "fetch_failed"} {
		status.Store(int32(code))
		if _, err := fetchFeedUsing(SubscriptionFetchRequest{URL: feed, ApprovedChain: loopbackApprovals(feed)}, loopback, transport); err == nil || err.Error() != want {
			t.Errorf("HTTP %d: %v, want %s", code, err, want)
		}
	}
	unresolved := func(context.Context, string, string) ([]netip.Addr, error) { return nil, errors.New("no such host") }
	if _, err := fetchFeedUsing(SubscriptionFetchRequest{URL: feed}, unresolved, transport); err == nil || err.Error() != "dns_failed" {
		t.Errorf("lookup failure: %v, want dns_failed", err)
	}
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, closedPort, _ := net.SplitHostPort(closed.Addr().String())
	_ = closed.Close()
	refused := "http://127.0.0.2:" + closedPort + "/feed"
	if _, err := fetchFeedUsing(SubscriptionFetchRequest{URL: refused, ApprovedChain: loopbackApprovals(refused)}, loopback, transport); err == nil || err.Error() != "provider_unreachable" {
		t.Errorf("refused connection: %v, want provider_unreachable", err)
	}
	// A blocked or overloaded domain still leaves its mirror a turn.
	for _, code := range []int{403, 429, 503} {
		status.Store(int32(code))
		result, err := fetchFeedUsing(SubscriptionFetchRequest{URL: feed, FallbackHosts: []string{"127.0.0.3"}, ApprovedChain: loopbackApprovals(feed, mirror)}, loopback, transport)
		if err != nil || result.(map[string]any)["body"] != "mirror" {
			t.Errorf("HTTP %d skipped the mirror: %v", code, err)
		}
	}
}

// A runetfreedom geosite.dat is 85 MB against the 64 MiB geofile limit (Elarni): a declared oversize body must fail
// at once with input_too_large, not after downloading the limit over mobile data, and an undeclared one the same way.
func TestFetchResourceRefusesBodiesOverTheLimit(t *testing.T) {
	const limit = 1024
	release := make(chan struct{})
	defer close(release)
	for _, declared := range []bool{true, false} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if declared {
				w.Header().Set("Content-Length", "1073741824")
				_, _ = w.Write([]byte{1})
				w.(http.Flusher).Flush()
				select { // the rest of a large body is still on its way
				case <-release:
				case <-r.Context().Done():
				}
				return
			}
			_, _ = w.Write([]byte{1}) // flushed first, so the body is chunked with no Content-Length
			w.(http.Flusher).Flush()
			_, _ = w.Write(make([]byte, limit))
		}))
		request := SubscriptionFetchRequest{URL: server.URL,
			ApprovedChain: []string{approvalFingerprint(server.URL, []string{"cleartext_http", "loopback_target"})}}
		started := time.Now()
		_, err := FetchResource(context.Background(), request, limit, 5*time.Second, true)
		server.Close()
		if err == nil || err.Error() != "input_too_large" || time.Since(started) > 2*time.Second {
			t.Fatalf("declared=%v: %v after %v", declared, err, time.Since(started))
		}
	}
}

// Geofiles go straight to disk (Elarni): an 85 MB body must not sit in memory, nor reach the app as base64.
func TestFetchResourceToFileStreamsTheBody(t *testing.T) {
	const limit = 1024
	body := bytes.Repeat([]byte{0, 255, 7}, 300)
	var mode atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"v1"`)
		switch mode.Load() {
		case 0:
			_, _ = w.Write(body)
		case 1:
			w.Header().Set("Content-Length", "2048")
			_, _ = w.Write(make([]byte, 2048))
		case 2:
			_, _ = w.Write([]byte{1}) // flushed first, so the body is chunked with no Content-Length
			w.(http.Flusher).Flush()
			_, _ = w.Write(make([]byte, limit))
		case 3:
			w.WriteHeader(http.StatusNotModified)
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	request := SubscriptionFetchRequest{URL: server.URL, ApprovedChain: loopbackApprovals(server.URL)}
	target := filepath.Join(dir, "geosite.dat")
	result, err := FetchResourceToFile(context.Background(), request, limit, 5*time.Second, target)
	value, _ := result.(map[string]any)
	saved, _ := os.ReadFile(target)
	if err != nil || value["bytes"] != int64(len(body)) || value["body"] != nil || value["etag"] != `"v1"` || !bytes.Equal(saved, body) {
		t.Fatalf("download: %v %v, saved %d bytes", value, err, len(saved))
	}
	for _, over := range []int32{1, 2} {
		mode.Store(over)
		target := filepath.Join(dir, "over.dat")
		if _, err := FetchResourceToFile(context.Background(), request, limit, 5*time.Second, target); err == nil || err.Error() != "input_too_large" {
			t.Fatalf("mode %d: %v, want input_too_large", over, err)
		}
		if _, err := os.Stat(target); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("mode %d: an over-limit body was left on disk", over)
		}
	}
	mode.Store(3)
	request.ETag = `"v1"`
	target = filepath.Join(dir, "unchanged.dat")
	result, err = FetchResourceToFile(context.Background(), request, limit, 5*time.Second, target)
	if value, _ := result.(map[string]any); err != nil || value["notModified"] != true {
		t.Fatalf("unchanged: %v %v", result, err)
	}
	if _, err := os.Stat(target); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("an unchanged resource wrote a file")
	}
}
