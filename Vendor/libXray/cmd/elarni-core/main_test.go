package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
	xerrors "github.com/xtls/xray-core/common/errors"
)

func TestNativeFailureRetainsTypedProbeDiagnostics(t *testing.T) {
	result := nativeResponse(map[string]any{"delay": 10000, "diagnostics": map[string]any{"stage": "target_request", "code": "connection_refused"}}, errors.New("ping_failed"))
	var response struct {
		Success bool
		Error   string
		Data    struct{ Diagnostics struct{ Stage, Code string } }
	}
	if json.Unmarshal([]byte(result), &response) != nil || response.Success || response.Error != "ping_failed" || response.Data.Diagnostics.Code != "connection_refused" || response.Data.Diagnostics.Stage != "target_request" {
		t.Fatal("native probe failure lost its diagnostics")
	}
}

func TestXrayStartupReportsStageAndCanRetryAfterPortConflict(t *testing.T) {
	if instance, err := xray.StartXrayFromJSON(`{"outbounds":[{"protocol":"invalid-fixture"}]}`); instance != nil || err == nil || !strings.HasPrefix(err.Error(), "xray_config_invalid:") {
		t.Fatalf("invalid configuration did not report its stage: %v", err)
	}
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	config := fmt.Sprintf(`{"log":{"loglevel":"none"},"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":%d}],"outbounds":[{"protocol":"freedom"}]}`, occupied.Addr().(*net.TCPAddr).Port)
	if instance, err := xray.StartXrayFromJSON(config); instance != nil || err == nil || !strings.HasPrefix(err.Error(), "xray_start_failed:") {
		t.Fatalf("port conflict did not report its stage: %v", err)
	}
	occupied.Close()
	instance, err := xray.StartXrayFromJSON(config)
	if err != nil {
		t.Fatalf("retry after port release failed: %v", err)
	}
	if err := instance.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPersistedProfilesCannotEnableLocalFileSideEffects(t *testing.T) {
	config := `{"log":{"loglevel":"none"},"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":1,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"},"streamSettings":{"security":"reality","realitySettings":{"fingerprint":"chrome","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverName":"example.org","MasterKeyLog":"/never-write/keys.log"}}}]}`
	if instance, err := xray.StartXrayFromJSON(config); err == nil {
		_ = instance.Close()
		t.Error("runtime accepted persisted key logging")
	} else if !strings.Contains(err.Error(), "key logging") {
		t.Errorf("runtime failed for unrelated reason: %v", err)
	}
	payload, _ := json.Marshal(map[string]string{"configJSON": config})
	if _, err, handled := dataRequest("validateConfig", payload); !handled || err == nil {
		t.Error("preflight accepted persisted key logging")
	}
	_, _, err := xray.PingJSONWithDiagnostics(config, 1, "http://127.0.0.1:1", "", "GET", "default", "baseline")
	if err == nil || !strings.Contains(err.Error(), "key logging") {
		t.Errorf("probe did not reject persisted key logging before startup: %v", err)
	}
}

func TestValidateConfigDoesNotStartListenersOrTUN(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("xray.tun.fd", "-1")
	config, _ := json.Marshal(map[string]any{
		"log": map[string]any{"loglevel": "none"},
		"inbounds": []any{
			map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": listener.Addr().(*net.TCPAddr).Port},
			map[string]any{"protocol": "tun", "settings": map[string]any{"name": "elarni-preflight-fixture"}},
		},
		"outbounds": []any{map[string]any{"protocol": "freedom"}},
	})
	for _, fixture := range []struct {
		config string
		valid  bool
	}{{string(config), true}, {`{"outbounds":[{"protocol":"private-secret"}]}`, false}} {
		request, _ := json.Marshal(map[string]any{"apiVersion": 1, "method": "validateConfig",
			"payload": map[string]any{"configJSON": fixture.config}})
		result := dispatch(string(request))
		var reply struct {
			Success bool
			Data    struct{ Valid bool }
		}
		if json.Unmarshal([]byte(result.text), &reply) != nil || reply.Success != fixture.valid ||
			reply.Data.Valid != fixture.valid || result.run || xray.GetXrayState() || strings.Contains(result.text, "private-secret") {
			t.Fatalf("preflight response: %s", result.text)
		}
	}
}

func TestDispatchOnlyAcceptsSafeOperationsAndRedactsErrors(t *testing.T) {
	for _, request := range []string{
		`{"apiVersion":1,"method":"runXray","payload":{"configPath":"private-secret"}}`,
		`{"apiVersion":2,"method":"importClientProfiles","payload":{"text":"private-secret"}}`,
		`{"apiVersion":1,"method":"importClientProfiles","payload":{"text":"private-secret"}}`,
		`{"apiVersion":1,"method":"runXrayFromJson","payload":{"configJSON":"private-secret"}}`,
		strings.Repeat("x", maxMessage+1),
	} {
		result := dispatch(request)
		var decoded struct{ Success bool }
		if result.run || json.Unmarshal([]byte(result.text), &decoded) != nil || decoded.Success || strings.Contains(result.text, "private-secret") {
			t.Fatalf("unsafe response: %s", result.text)
		}
	}
}

func TestParentEOFDuringStartupDoesNotWaitForStartup(t *testing.T) {
	input, parent := io.Pipe()
	defer input.Close()
	defer parent.Close()
	started, release, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer close(release)
	done := make(chan int, 1)
	go func() {
		done <- serve(input, io.Discard, func(string) response {
			close(started)
			<-release
			return response{}
		}, func() error { close(stopped); return nil }, func() bool { return true })
	}()
	_, _ = io.WriteString(parent, "{}\n")
	<-started
	_ = parent.Close()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("EOF waited for startup")
	}
	<-stopped
}

func TestParentEOFAfterReadinessStopsCore(t *testing.T) {
	input, parent := io.Pipe()
	output, child := io.Pipe()
	defer input.Close()
	defer parent.Close()
	defer output.Close()
	defer child.Close()
	stopped := make(chan struct{})
	done := make(chan int, 1)
	go func() {
		done <- serve(input, child, func(string) response {
			return response{text: `{"success":true}`, run: true}
		}, func() error { close(stopped); return nil }, func() bool { return true })
	}()
	_, _ = io.WriteString(parent, "{}\n")
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || line != "{\"success\":true}\n" {
		t.Fatal("missing readiness response")
	}
	_ = parent.Close()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("core survived parent EOF")
	}
	<-stopped
}

type failedWriter struct{}

func (failedWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestOutputFailureStopsCore(t *testing.T) {
	input, parent := io.Pipe()
	defer input.Close()
	defer parent.Close()
	go func() { _, _ = io.WriteString(parent, "{}\n") }()
	stopped := false
	code := serve(input, failedWriter{}, func(string) response {
		return response{text: `{"success":true}`, run: true}
	}, func() error { stopped = true; return nil }, func() bool { return true })
	if code != 1 || !stopped {
		t.Fatal("output failure did not stop the core")
	}
}

type blockedWriter struct{ started, release chan struct{} }

func (w blockedWriter) Write(data []byte) (int, error) {
	close(w.started)
	<-w.release
	return len(data), nil
}

func TestParentEOFWhileOutputIsBlockedStopsCore(t *testing.T) {
	input, parent := io.Pipe()
	defer input.Close()
	defer parent.Close()
	writer := blockedWriter{make(chan struct{}), make(chan struct{})}
	defer close(writer.release)
	done := make(chan int, 1)
	go func() {
		done <- serve(input, writer, func(string) response {
			return response{text: `{"success":true}`, run: true}
		}, func() error { return nil }, func() bool { return true })
	}()
	_, _ = io.WriteString(parent, "{}\n")
	<-writer.started
	_ = parent.Close()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("EOF waited for a blocked output pipe")
	}
}

func TestOversizedInputNeverInvokesCore(t *testing.T) {
	called := false
	serve(bytes.NewReader(bytes.Repeat([]byte("x"), maxMessage+1)), io.Discard,
		func(string) response { called = true; return response{} },
		func() error { return nil }, func() bool { return false })
	if called {
		t.Fatal("oversized input reached the core")
	}
}

func TestVPNSessionReconnectAndOwnerEOF(t *testing.T) {
	input, parent := io.Pipe()
	output, child := io.Pipe()
	defer input.Close()
	defer parent.Close()
	defer output.Close()
	defer child.Close()
	stopped := make(chan struct{})
	done := make(chan int, 1)
	go func() {
		done <- serve(input, child, func(raw string) response {
			var request struct {
				Method string `json:"method"`
			}
			_ = json.Unmarshal([]byte(raw), &request)
			return response{text: `{"success":true}`, run: request.Method == "runVPN", session: request.Method == "runVPN"}
		}, func() error { close(stopped); return nil }, func() bool { return true })
	}()
	reader := bufio.NewReader(output)
	for _, method := range []string{"runVPN", "stopVPN", "runVPN", "stopVPN"} {
		_, _ = io.WriteString(parent, `{"apiVersion":1,"method":"`+method+`","payload":{"reuseSession":true}}`+"\n")
		line, err := reader.ReadString('\n')
		if err != nil || line != "{\"success\":true}\n" {
			t.Fatal("session command failed", method, err)
		}
		select {
		case <-stopped:
			t.Fatal("session owner stopped between tunnels")
		default:
		}
	}
	_ = parent.Close()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("idle session survived owner EOF")
	}
	<-stopped
}

func TestVPNSessionRejectsUnrelatedCommandsAndCancelsRestart(t *testing.T) {
	for _, method := range []string{"importClientProfiles", "runVPN"} {
		t.Run(method, func(t *testing.T) {
			requests := make(chan string, 1)
			closed := make(chan struct{})
			requests <- `{"apiVersion":1,"method":"` + method + `"}`
			called := false
			if serveVPNSession(requests, closed, io.Discard, func(string) response { called = true; return response{} }, func() bool { return true }, false, 0) != 1 || called {
				t.Fatal("unexpected command reached the runtime")
			}
		})
	}
	requests := make(chan string, 1)
	closed, started, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer close(release)
	done := make(chan int, 1)
	requests <- `{"apiVersion":1,"method":"stopVPN"}`
	go func() {
		done <- serveVPNSession(requests, closed, io.Discard, func(string) response { close(started); <-release; return response{} }, func() bool { return true }, false, 0)
	}()
	<-started
	close(closed)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("session cancellation waited for command")
	}
}

func TestCatalogLeaseServesStorageUntilOwnerEOF(t *testing.T) {
	input, parent := io.Pipe()
	output, child := io.Pipe()
	defer input.Close()
	defer parent.Close()
	defer output.Close()
	defer child.Close()
	replies := map[string][]string{
		"acquireCatalog": {`{"success":true}`},
		"loadCatalog":    {`{"success":true,"data":{"revision":""}}`},
		// A rejected write is a reply, not the end of the lease.
		"saveCatalog": {`{"success":false,"error":"storage_conflict"}`, `{"success":true,"data":{"revision":"r"}}`},
		// Each Windows connect first checks for a crashed helper's DNS guard.
		"staleVPNGuard": {`{"success":true,"data":{"stale":false}}`},
	}
	var invoked []string
	done := make(chan int, 1)
	go func() {
		code := serve(input, child, func(raw string) response {
			var request struct {
				Method string `json:"method"`
			}
			_ = json.Unmarshal([]byte(raw), &request)
			invoked = append(invoked, request.Method)
			text := replies[request.Method][0]
			replies[request.Method] = replies[request.Method][1:]
			return response{text: text, hold: request.Method == "acquireCatalog"}
		}, func() error { return nil }, func() bool { return false })
		_ = child.Close() // An early exit fails the read below instead of hanging it.
		done <- code
	}()
	reader := bufio.NewReader(output)
	for _, method := range []string{"acquireCatalog", "loadCatalog", "saveCatalog", "staleVPNGuard", "saveCatalog"} {
		_, _ = io.WriteString(parent, `{"apiVersion":1,"method":"`+method+`","payload":{}}`+"\n")
		line, err := reader.ReadString('\n')
		if err != nil || !strings.HasPrefix(line, `{"success":`) {
			t.Fatal("lease command failed", method, err)
		}
	}
	_ = parent.Close()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("lease survived owner EOF")
	}
	if strings.Join(invoked, ",") != "acquireCatalog,loadCatalog,saveCatalog,staleVPNGuard,saveCatalog" {
		t.Fatal("unexpected lease commands", invoked)
	}
}

func TestCatalogLeaseEndsOnOtherCommands(t *testing.T) {
	for _, raw := range []string{
		`{"apiVersion":1,"method":"acquireCatalog"}`,
		`{"apiVersion":1,"method":"runVPN","payload":{"reuseSession":true}}`,
		`{"apiVersion":1,"method":"importClientProfiles"}`,
		`{"apiVersion":2,"method":"saveCatalog"}`,
		`not json`,
	} {
		requests := make(chan string, 1)
		requests <- raw
		called := false
		if serveCatalogLease(requests, make(chan struct{}), io.Discard, func(string) response { called = true; return response{} }) != 1 || called {
			t.Fatal("lease ran an unrelated command", raw)
		}
	}
}

// The desktop app shows the core's log: each tick sends the lines recorded since
// this core started, already redacted, whether it runs Xray or relays a helper.
func TestCoreStreamsItsNewRedactedLogLines(t *testing.T) {
	defer xray.SetLogLevel("warning")
	for _, payload := range []string{`{"logLevel":"loud"}`, `{"logLevel":7}`} {
		if result := dispatch(`{"apiVersion":1,"method":"runXrayFromJson","payload":` + payload + `}`); result.run || !strings.Contains(result.text, "invalid_request") {
			t.Fatalf("%s: %s", payload, result.text)
		}
	}
	result := dispatch(`{"apiVersion":1,"method":"runXrayFromJson","payload":{"logLevel":"info","configJSON":"{\"outbounds\":[{\"protocol\":\"freedom\"}]}"}}`)
	if !result.run || xray.LogLevel() != "info" {
		t.Fatalf("run %v at %s: %s", result.run, xray.LogLevel(), result.text)
	}
	if err := xray.StopXray(); err != nil {
		t.Fatal(err)
	}
	xerrors.LogWarning(context.Background(), "a line from before this core")
	for _, mode := range []struct {
		method string
		record func()
		want   string
	}{
		{"runXrayFromJson", func() { xerrors.LogWarning(context.Background(), "dial 203.0.113.9:443 failed") }, "dial [ip]:443 failed"},
		{"runVPN", func() { xray.AppendLogs([]xray.LogEntry{{Time: 1, Level: "error", Text: "helper stopped"}}) }, "helper stopped"},
	} {
		input, parent := io.Pipe()
		output, child := io.Pipe()
		done := make(chan int, 1)
		go func() {
			done <- serve(input, child, func(string) response {
				mode.record()
				return response{text: `{"success":true}`, run: true, session: mode.method == "runVPN"}
			}, func() error { return nil }, func() bool { return true })
		}()
		_, _ = io.WriteString(parent, `{"apiVersion":1,"method":"`+mode.method+`","payload":{}}`+"\n")
		lines := make(chan string, 4)
		go func() {
			reader := bufio.NewReader(output)
			for {
				line, err := reader.ReadString('\n')
				if err != nil {
					close(lines)
					return
				}
				lines <- line
			}
		}()
		if line := <-lines; line != "{\"success\":true}\n" {
			t.Fatalf("%s: reply %q", mode.method, line)
		}
		var event struct {
			Event string          `json:"event"`
			Data  xray.LogsResult `json:"data"`
		}
		select {
		case line := <-lines:
			if json.Unmarshal([]byte(line), &event) != nil || event.Event != "logs" || len(event.Data.Entries) != 1 ||
				!strings.HasSuffix(event.Data.Entries[0].Text, mode.want) {
				t.Fatalf("%s: event %q", mode.method, line)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s: no log event", mode.method)
		}
		_ = parent.Close()
		_ = output.Close()
		<-done
		_ = input.Close()
		_ = child.Close()
	}
}
