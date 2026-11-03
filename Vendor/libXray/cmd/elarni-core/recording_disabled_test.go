//go:build !elarni_recording && !elarni_diagnostics

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xtls/xray-core/common/flightrecorder"
)

// A core built without the recording option never records, whatever the app sends.
func TestCoreWithoutTheOptionNeverRecords(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("LocalAppData", cache)
	t.Setenv("XDG_CACHE_HOME", cache)
	t.Setenv("HOME", cache) // macOS caches live under $HOME/Library/Caches
	diagnosticsRequest("runXrayFromJson", json.RawMessage(`{"recordDiagnostics":true}`))
	if flightrecorder.Enabled() {
		t.Fatal("recording started without the build option")
	}
	destination, _ := json.Marshal(filepath.Join(t.TempDir(), "recording.zip"))
	for _, payload := range []string{`{"action":"mark"}`, `{"action":"export","destination":` + string(destination) + `}`} {
		if reply := dispatch(`{"apiVersion":1,"method":"diagnostics","payload":` + payload + `}`).text; strings.Contains(reply, `"success":true`) {
			t.Fatalf("%s: %s", payload, reply)
		}
	}
	if entries, _ := os.ReadDir(cache); len(entries) != 0 {
		t.Fatal("a recording directory was created")
	}
}
