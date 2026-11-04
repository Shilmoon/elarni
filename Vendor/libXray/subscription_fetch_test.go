package libXray

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestRoutingResourceFFIPinsPolicyAndPreservesLargeBinaryBody(t *testing.T) {
	body := bytes.Repeat([]byte{0, 255, 128, 7}, 13*1024*1024/4)
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = w.Write(body)
	}))
	defer server.Close()
	invoke := func(method string, payload map[string]any) map[string]any {
		request, _ := json.Marshal(map[string]any{"apiVersion": 1, "method": method, "payload": payload})
		var result map[string]any
		if err := json.Unmarshal([]byte(Invoke(string(request))), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	// A geofile streams to the file the app names (Elarni), never through this JSON.
	for _, destination := range []any{nil, "", "geosite.dat"} {
		request := map[string]any{"operationId": "00000000-0000-4000-8000-000000000003", "url": server.URL, "resourceKind": "geofile"}
		if destination != nil {
			request["destination"] = destination
		}
		invoke("prepareFetch", request)
		if result := invoke("fetchResource", request); result["success"] != false || result["error"] != "invalid_fetch_options" {
			t.Fatalf("destination %v: %v", destination, result)
		}
		invoke("releaseFetch", request)
	}
	destination := filepath.Join(t.TempDir(), "geosite.dat")
	request := map[string]any{"operationId": "00000000-0000-4000-8000-000000000004", "url": server.URL, "resourceKind": "geofile", "destination": destination}
	invoke("prepareFetch", request)
	result := invoke("fetchResource", request)
	if result["success"] != true {
		t.Fatalf("resource method failed: %v", result["error"])
	}
	warning := result["data"].(map[string]any)["warning"].(map[string]any)
	if calls.Load() != 0 {
		t.Fatal("unapproved resource reached private server")
	}
	request["approvedChain"] = warning["chain"]
	request["operationId"] = "00000000-0000-4000-8000-000000000005"
	invoke("prepareFetch", request)
	result = invoke("fetchResource", request)
	if result["success"] != true {
		t.Fatalf("binary resource failed: %v", result["error"])
	}
	data := result["data"].(map[string]any)
	saved, err := os.ReadFile(destination)
	if err != nil || !bytes.Equal(saved, body) || data["bytes"] != float64(len(body)) || data["body"] != nil || calls.Load() != 1 {
		t.Fatal("resource FFI lost binary bytes or fetched more than once")
	}
	request["resourceKind"] = "domains"
	delete(request, "destination")
	request["operationId"] = "00000000-0000-4000-8000-000000000006"
	invoke("prepareFetch", request)
	if invoke("fetchResource", request)["success"] != false {
		t.Fatal("managed domains exceeded their 4 MiB limit")
	}
	request["operationId"] = "00000000-0000-4000-8000-000000000007"
	before := calls.Load()
	invoke("prepareFetch", request)
	invoke("cancelFetch", request)
	if invoke("fetchResource", request)["success"] != false || calls.Load() != before {
		t.Fatal("cancelled resource started")
	}
	invoke("releaseFetch", request)
}

func TestSubscriptionFetchCancellationBeforeAndDuringDispatch(t *testing.T) {
	var calls atomic.Int32
	entered := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		entered <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	invoke := func(method LibXrayMethod, payload map[string]any) map[string]any {
		bytes, _ := json.Marshal(payload)
		var result map[string]any
		if err := json.Unmarshal([]byte(invokeFetch(method, bytes)), &result); err != nil {
			t.Error(err)
		}
		return result
	}
	request := map[string]any{"operationId": "00000000-0000-4000-8000-000000000001", "url": server.URL}
	invoke(LibXrayMethodPrepareFetch, request)
	invoke(LibXrayMethodCancelFetch, request)
	if invoke(LibXrayMethodFetchSubscription, request)["success"] != false || calls.Load() != 0 {
		t.Fatal("cancelled fetch started")
	}
	invoke(LibXrayMethodReleaseFetch, request)
	request["operationId"] = "00000000-0000-4000-8000-000000000002"
	invoke(LibXrayMethodPrepareFetch, request)
	result := invoke(LibXrayMethodFetchSubscription, request)
	request["approvedChain"] = result["data"].(map[string]any)["warning"].(map[string]any)["chain"]
	request["operationId"] = "00000000-0000-4000-8000-000000000003"
	invoke(LibXrayMethodPrepareFetch, request)
	done := make(chan map[string]any, 1)
	go func() { done <- invoke(LibXrayMethodFetchSubscription, request) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("fetch did not start")
	}
	invoke(LibXrayMethodCancelFetch, request)
	select {
	case result := <-done:
		if result["success"] != false {
			t.Fatal("cancelled fetch succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("active fetch did not cancel")
	}
	invoke(LibXrayMethodReleaseFetch, request)
}

// Every platform shows the device ID through this method.
func TestSubscriptionDeviceIDMethod(t *testing.T) {
	invoke := func(payload map[string]any) map[string]any {
		request, _ := json.Marshal(map[string]any{"apiVersion": 1, "method": "subscriptionDeviceID", "payload": payload})
		var result map[string]any
		if err := json.Unmarshal([]byte(Invoke(string(request))), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	request := map[string]any{"url": "https://provider.example/feed", "installationId": "installation"}
	plain := invoke(request)
	request["deviceSalt"] = "reset"
	reset := invoke(request)
	id := func(result map[string]any) string { return result["data"].(map[string]any)["deviceId"].(string) }
	if plain["success"] != true || reset["success"] != true || len(id(plain)) != 64 || id(plain) == id(reset) {
		t.Fatal(plain, reset)
	}
	if invoke(map[string]any{"url": "provider.example"})["success"] != false {
		t.Fatal("an invalid URL got a device ID")
	}
}
