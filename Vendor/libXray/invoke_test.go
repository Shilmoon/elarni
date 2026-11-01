package libXray

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/common/errors"
)

// A single successful probe cannot catch serial admission or one temporary
// core using another core's DNS settings. Exercise the production Invoke/HTTP
// boundary with all 26 requests held open and conflicting static host maps.
func TestParallelProbesKeepIndependentDNSAndCompleteInOneRound(t *testing.T) {
	const count = 26
	arrived := make(chan struct{}, count)
	release := make(chan struct{})
	servers := make([]*http.Server, 0, 2)
	port := 0
	addresses := []string{"127.0.0.1", "::1"}
	for index, address := range addresses {
		listener, err := net.Listen("tcp", net.JoinHostPort(address, fmt.Sprint(port)))
		if err != nil {
			t.Fatal(err)
		}
		port = listener.Addr().(*net.TCPAddr).Port
		body := fmt.Sprintf("fixture-%d", index)
		server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			arrived <- struct{}{}
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
			time.Sleep(200 * time.Millisecond)
			fmt.Fprint(w, body)
		})}
		servers = append(servers, server)
		go server.Serve(listener)
	}
	defer func() {
		for _, server := range servers {
			_ = server.Close()
		}
	}()
	reserved := make([]net.Listener, count)
	for index := range reserved {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		reserved[index] = listener
		defer listener.Close()
	}
	var workers sync.WaitGroup
	workers.Add(count)
	replies := make([]invokeResponse, count)
	started := time.Now()
	for index := range count {
		go func() {
			defer workers.Done()
			socks := reserved[index].Addr().(*net.TCPAddr).Port
			_ = reserved[index].Close()
			config := fmt.Sprintf(`{"log":{"loglevel":"none"},"dns":{"hosts":{"probe.test":"%s"}},"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"socks"}],"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIP"}}]}`, addresses[index%2], socks)
			operation := fmt.Sprintf("00000000-0000-4000-8000-%012x", index)
			payload, _ := json.Marshal(map[string]any{"operationId": operation, "configJSON": config, "proxy": fmt.Sprintf("socks5://127.0.0.1:%d", socks),
				"url": fmt.Sprintf("http://probe.test:%d/parallel", port), "method": "GET", "mode": "default", "timeout": 4,
				"expectedStatus": 200, "expectedBody": fmt.Sprintf("fixture-%d", index%2)})
			if err := json.Unmarshal([]byte(invokeProbeOperation(LibXrayMethodPrepareProbe, payload)), &replies[index]); err != nil {
				t.Error(err)
				return
			}
			defer invokeProbeOperation(LibXrayMethodReleaseProbe, payload)
			if !replies[index].Success {
				return
			}
			if err := json.Unmarshal([]byte(invokePing(payload)), &replies[index]); err != nil {
				t.Error(err)
			}
		}()
	}
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	reached := 0
wait:
	for reached < count {
		select {
		case <-arrived:
			reached++
		case <-deadline.C:
			break wait
		}
	}
	close(release)
	workers.Wait()
	t.Logf("26 parallel proxy probes: %s; %d reached responder together", time.Since(started), reached)
	if reached != count {
		t.Errorf("only %d/%d probes reached the responder before release", reached, count)
	}
	for index, reply := range replies {
		if !reply.Success {
			t.Errorf("probe %d failed: %s", index, reply.Err)
		}
	}
	if time.Since(started) >= 3*time.Second {
		t.Error("probes did not complete in one round")
	}
}

// Exercise the same dispatcher used by CGoInvoke and the desktop helper. A
// malformed feed must be an import error, never a process-wide panic.
func TestImportRejectsNullTLSCertificateThroughInvoke(t *testing.T) {
	for _, certificates := range []string{`[null]`, `[{"certificate":["fixture"]},null]`} {
		t.Run(certificates, func(t *testing.T) {
			profile := `{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":1080}]},"streamSettings":{"security":"tls","tlsSettings":{"certificates":` + certificates + `}}}`
			request, err := json.Marshal(map[string]any{"apiVersion": 1, "method": "importClientProfiles", "payload": map[string]any{"text": profile}})
			if err != nil {
				t.Fatal(err)
			}
			var response invokeResponse
			if err := json.Unmarshal([]byte(Invoke(string(request))), &response); err != nil {
				t.Fatal(err)
			}
			if response.Success || response.Err == "" || len(response.Err) > 1024 || strings.Contains(response.Err, "127.0.0.1") {
				t.Fatalf("expected bounded validation error, got %+v", response)
			}
		})
	}
	request := `{"apiVersion":1,"method":"importClientProfiles","payload":{"text":"socks://127.0.0.1:1080"}}`
	var response invokeResponse
	if err := json.Unmarshal([]byte(Invoke(request)), &response); err != nil || !response.Success {
		t.Fatalf("valid import after rejected input failed: %v, %+v", err, response)
	}
}

// A provider's broken move hint must not freeze a feed whose servers parse.
func TestImportKeepsServersWhenTheMigrationHintIsInvalid(t *testing.T) {
	for name, headers := range map[string]map[string]string{
		"port in New-Domain":    {"new-domain": "mirror.example:8443"},
		"http new-url on https": {"new-url": "http://mirror.example/feed"},
	} {
		t.Run(name, func(t *testing.T) {
			request, err := json.Marshal(map[string]any{"apiVersion": 1, "method": "importClientProfiles", "payload": map[string]any{
				"text": "socks://127.0.0.1:1080", "sourceURL": "https://feed.example/sub", "migrationHeaders": headers,
			}})
			if err != nil {
				t.Fatal(err)
			}
			var response struct {
				Success bool   `json:"success"`
				Err     string `json:"error"`
				Data    struct {
					Profiles     []json.RawMessage `json:"profiles"`
					NewSourceURL string            `json:"newSourceURL"`
				} `json:"data"`
			}
			if err := json.Unmarshal([]byte(Invoke(string(request))), &response); err != nil {
				t.Fatal(err)
			}
			if !response.Success || len(response.Data.Profiles) != 1 || response.Data.NewSourceURL != "" {
				t.Fatalf("invalid hint broke a working feed: %+v", response)
			}
		})
	}
}

func TestPingInvalidTargetRetainsDiagnostic(t *testing.T) {
	for _, target := range []string{"", "not-a-url", "https:///missing-host"} {
		t.Run(target, func(t *testing.T) {
			payload, err := json.Marshal(map[string]any{
				"configJSON": "{}", "url": target, "timeout": 1,
				"method": "GET", "mode": "default", "expectedStatus": 204, "expectedBody": "",
			})
			if err != nil {
				t.Fatal(err)
			}
			var response struct {
				Success bool         `json:"success"`
				Error   string       `json:"error"`
				Data    PingResponse `json:"data"`
			}
			if err := json.Unmarshal([]byte(invokePing(payload)), &response); err != nil {
				t.Fatal(err)
			}
			if response.Success || response.Error != "invalid_target" ||
				response.Data.Diagnostics == nil || response.Data.Diagnostics.Code != "invalid_target" ||
				response.Data.Diagnostics.TransportCode != "invalid_target" {
				t.Fatalf("invalid target lost its diagnostic: %+v", response)
			}
		})
	}
}

// Check exit reads Cloudflare's trace through one server: a temporary core, or the
// running one on Apple, names the address and country the request left from.
func TestExitTraceNamesWhereTheServerLeavesTheInternet(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	trace := "fl=29f\nh=cp.cloudflare.com\nip=203.0.113.7\nts=1761730000.1\nvisit_scheme=https\ncolo=FRA\nloc=DE\ntls=TLSv1.3\nwarp=off\n"
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/cdn-cgi/trace":
			fmt.Fprint(w, trace)
		case "/no-country":
			fmt.Fprint(w, "ip=203.0.113.7\ncolo=FRA\n")
		default:
			fmt.Fprint(w, "ip=not-an-address\nloc=DE\n")
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	socks := reserved.Addr().(*net.TCPAddr).Port
	_ = reserved.Close()
	freedom := `{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}`
	ping := func(path string, extra map[string]any) (bool, string, PingResponse) {
		request := map[string]any{"configJSON": fmt.Sprintf(`{"log":{"loglevel":"none"},"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"socks"}],"outbounds":[%s]}`, socks, freedom),
			"proxy": fmt.Sprintf("socks5://127.0.0.1:%d", socks), "url": "http://" + listener.Addr().String() + path, "timeout": 4,
			"method": "GET", "mode": "default", "expectedStatus": 200, "expectedBody": "", "trace": true}
		for key, value := range extra {
			if value == nil {
				delete(request, key)
			} else {
				request[key] = value
			}
		}
		payload, _ := json.Marshal(request)
		var response struct {
			Success bool         `json:"success"`
			Error   string       `json:"error"`
			Data    PingResponse `json:"data"`
		}
		if err := json.Unmarshal([]byte(invokePing(payload)), &response); err != nil {
			t.Fatal(err)
		}
		return response.Success, response.Error, response.Data
	}
	ok, code, data := ping("/cdn-cgi/trace", nil)
	if !ok || data.Exit == nil || data.Exit.IP != "203.0.113.7" || data.Exit.Country != "DE" || data.Delay < 0 {
		t.Fatalf("the exit was not named: %v %q %+v", ok, code, data.Exit)
	}
	// The probe core reports a failed check under its own diagnostic code.
	for _, path := range []string{"/no-country", "/bad-address"} {
		if ok, code, data := ping(path, nil); ok || code == "" || data.Exit != nil {
			t.Fatalf("%s: an unreadable trace passed: %v %q %+v", path, ok, code, data.Exit)
		}
	}
	// A plain test names no exit, and a trace needs a GET.
	if ok, _, data := ping("/cdn-cgi/trace", map[string]any{"trace": nil, "expectedBody": trace}); !ok || data.Exit != nil {
		t.Fatalf("a plain test changed: %v %+v", ok, data.Exit)
	}
	if ok, code, _ := ping("/cdn-cgi/trace", map[string]any{"method": "HEAD"}); ok || code != "invalid_response_contract" {
		t.Fatalf("a HEAD trace was accepted: %v %q", ok, code)
	}
	if err := xray.RunXrayFromJSON(`{"outbounds":[` + freedom + `]}`); err != nil {
		t.Fatal(err)
	}
	ok, code, data = ping("/cdn-cgi/trace", map[string]any{"runningCore": true, "configJSON": nil, "proxy": nil})
	if err := xray.StopXray(); err != nil {
		t.Fatal(err)
	}
	if !ok || data.Exit == nil || data.Exit.Country != "DE" {
		t.Fatalf("the running core named no exit: %v %q %+v", ok, code, data.Exit)
	}
}

// The tunnel's liveness check goes through the running core's routing, without a
// listener login or a second core.
func TestPingThroughTheRunningCore(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })}
	go server.Serve(listener)
	defer server.Close()
	ping := func(extra map[string]any) (bool, string) {
		request := map[string]any{"runningCore": true, "url": "http://" + listener.Addr().String() + "/", "timeout": 2,
			"method": "GET", "expectedStatus": 204, "expectedBody": ""}
		for key, value := range extra {
			request[key] = value
		}
		payload, _ := json.Marshal(request)
		var response struct {
			Success bool   `json:"success"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal([]byte(invokePing(payload)), &response); err != nil {
			t.Fatal(err)
		}
		return response.Success, response.Error
	}
	if ok, code := ping(nil); ok || code != "not_connected" {
		t.Fatalf("a probe without a core: %v %q", ok, code)
	}
	for _, outbound := range []struct {
		config string
		passes bool
	}{
		{`{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}`, true},
		{`{"protocol":"blackhole"}`, false},
	} {
		if err := xray.RunXrayFromJSON(`{"outbounds":[` + outbound.config + `]}`); err != nil {
			t.Fatal(err)
		}
		ok, code := ping(nil)
		if err := xray.StopXray(); err != nil {
			t.Fatal(err)
		}
		if ok != outbound.passes {
			t.Fatalf("%s: passed=%v %q", outbound.config, ok, code)
		}
	}
	if ok, code := ping(map[string]any{"proxy": "socks5://127.0.0.1:1"}); ok || code != "invalid_running_core_probe" {
		t.Fatalf("a running-core probe took a proxy: %v %q", ok, code)
	}
}

// Each platform reads the core log and sets its level through Invoke.
func TestLogsThroughInvoke(t *testing.T) {
	call := func(method string, payload any) (bool, map[string]any) {
		body, _ := json.Marshal(map[string]any{"apiVersion": 1, "method": method, "payload": payload})
		var response struct {
			Success bool           `json:"success"`
			Data    map[string]any `json:"data"`
		}
		if err := json.Unmarshal([]byte(Invoke(string(body))), &response); err != nil {
			t.Fatal(err)
		}
		return response.Success, response.Data
	}
	defer xray.SetLogLevel("warning")
	if ok, _ := call("setLogLevel", map[string]any{"level": "loud"}); ok {
		t.Fatal("an unknown level was accepted")
	}
	if ok, data := call("setLogLevel", map[string]any{"level": "info"}); !ok || data["level"] != "info" {
		t.Fatalf("setLogLevel: %v %v", ok, data)
	}
	_, before := call("readLogs", map[string]any{})
	entries, _ := before["entries"].([]any)
	after := int64(0)
	if len(entries) > 0 {
		after = int64(entries[len(entries)-1].(map[string]any)["seq"].(float64))
	}
	errors.LogInfo(context.Background(), "reached 192.0.2.10")
	ok, data := call("readLogs", map[string]any{"after": after})
	entries, _ = data["entries"].([]any)
	if !ok || data["level"] != "info" || len(entries) != 1 ||
		!strings.HasSuffix(entries[0].(map[string]any)["text"].(string), "reached [ip]") {
		t.Fatalf("readLogs: %v %v", ok, data)
	}
}
