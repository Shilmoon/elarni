//go:build elarni_benchmark

package main

// Standalone benchmark build only. Never install this helper in the app bundle.
import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

func benchmarkExit(code string) {
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"success": false, "error": code})
	os.Exit(2)
}

func benchmarkController(iface *net.Interface, allowLoopback bool) func(string, string, syscall.RawConn) error {
	return func(network, address string, raw syscall.RawConn) error {
		if target, err := netip.ParseAddrPort(address); err == nil && target.Addr().IsLoopback() {
			if allowLoopback {
				return nil // Only the benchmark's loopback listeners/fixtures.
			}
			return errors.New("loopback_outbound_rejected")
		}
		var bindErr error
		err := raw.Control(func(fd uintptr) { bindErr = benchmarkBind(fd, iface) })
		if err != nil {
			return err
		}
		return bindErr
	}
}

func init() {
	if len(os.Args) == 2 && os.Args[1] == "--benchmark-info" {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"benchmarkSchema": 1, "requiredInterfaceBinding": true})
		os.Exit(0)
	}
	name := os.Getenv("ELARNI_BENCH_INTERFACE")
	iface, err := net.InterfaceByName(name)
	if err != nil || iface.Flags&net.FlagUp == 0 {
		benchmarkExit("interface_unavailable")
	}
	if iface.Flags&net.FlagLoopback != 0 && os.Getenv("ELARNI_BENCH_LOOPBACK_FIXTURE") != "1" {
		benchmarkExit("physical_interface_required")
	}
	for _, prefix := range []string{"utun", "tun", "tap", "wg", "elarni"} {
		if strings.HasPrefix(strings.ToLower(name), prefix) {
			benchmarkExit("physical_interface_required")
		}
	}
	control := benchmarkController(iface, os.Getenv("ELARNI_BENCH_LOOPBACK_FIXTURE") == "1")
	internet.RequiredSocketController = control
	// Listener controllers are advisory in Xray. Terminate this isolated helper
	// on bind failure so an outbound datagram listener cannot silently escape.
	_ = internet.RegisterListenerController(func(network, address string, raw syscall.RawConn) error {
		if err := benchmarkController(iface, true)(network, address, raw); err != nil {
			benchmarkExit("interface_bind_failed")
		}
		return nil
	})
	resolverIP := os.Getenv("ELARNI_BENCH_DNS")
	if resolverIP == "" {
		resolverIP = "1.1.1.1"
	}
	if _, err := netip.ParseAddr(resolverIP); err != nil {
		benchmarkExit("invalid_bootstrap_dns")
	}
	resolverDialer := net.Dialer{Timeout: 5 * time.Second, Control: control}
	// Force the Go resolver: neither cgo/system DNS nor the active VPN's resolver
	// participates in endpoint bootstrap. TCP fallback uses the same binding.
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		return resolverDialer.DialContext(ctx, network, net.JoinHostPort(resolverIP, "53"))
	}}
	// Xray keeps a package-level alias used by SRV/TXT and finalmask lookups.
	xnet.DefaultResolver = net.DefaultResolver
	if len(os.Args) == 2 && os.Args[1] == "--benchmark-fetch" {
		benchmarkFetch(control)
		os.Exit(0)
	}
}

func benchmarkFetch(control func(string, string, syscall.RawConn) error) {
	var request struct {
		URL string `json:"url"`
	}
	if json.NewDecoder(io.LimitReader(os.Stdin, 16385)).Decode(&request) != nil {
		benchmarkExit("invalid_subscription_url")
	}
	u, err := url.Parse(request.URL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		benchmarkExit("https_subscription_required")
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second, Control: control, Resolver: net.DefaultResolver}
	transport := &http.Transport{Proxy: nil, DialContext: dialer.DialContext, TLSHandshakeTimeout: 10 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 || req.URL.Scheme != "https" || req.URL.User != nil {
			return errors.New("redirect_rejected")
		}
		return nil
	}}
	req, err := http.NewRequest(http.MethodGet, request.URL, nil)
	if err != nil {
		benchmarkExit("invalid_subscription_url")
	}
	req.Header.Set("User-Agent", "Elarni-Live-Benchmark/1")
	response, err := client.Do(req)
	if err != nil {
		benchmarkExit("subscription_fetch_failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		benchmarkExit("subscription_http_error")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024+1))
	if err != nil || len(body) == 0 || len(body) > 4*1024*1024 {
		benchmarkExit("subscription_body_invalid")
	}
	// This response is consumed only by the parent in memory, never a report.
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"success": true, "data": map[string]string{"text": string(body)}})
}
