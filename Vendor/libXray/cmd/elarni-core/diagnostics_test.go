//go:build elarni_recording && !elarni_diagnostics

package main

import (
	"archive/zip"
	"encoding/json"
	"io"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xtls/xray-core/common/flightrecorder"
)

func TestRecordingFollowsTheSwitchAndExportsMarks(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("LocalAppData", cache)
	t.Setenv("XDG_CACHE_HOME", cache)
	t.Setenv("HOME", cache) // macOS caches live under $HOME/Library/Caches
	call := func(payload string) string {
		return dispatch(`{"apiVersion":1,"method":"diagnostics","payload":` + payload + `}`).text
	}
	destination := filepath.Join(t.TempDir(), "recording.zip")
	if reply := call(`{"action":"export","destination":` + jsonString(destination) + `}`); !strings.Contains(reply, `"recording_empty"`) {
		t.Fatalf("empty export: %s", reply)
	}
	// Only Mark and Export are served; the directory is never the caller's choice.
	for _, payload := range []string{`{"action":"start","directory":"/tmp/elsewhere"}`, `{"action":"stop"}`, `{"action":"flush"}`, `[]`} {
		if reply := call(payload); !strings.Contains(reply, `"invalid_request"`) || flightrecorder.Enabled() {
			t.Fatalf("%s: %s", payload, reply)
		}
	}
	diagnosticsRequest("runXrayFromJson", json.RawMessage(`{"recordDiagnostics":false}`))
	if flightrecorder.Enabled() {
		t.Fatal("recording started with the switch off")
	}
	diagnosticsRequest("runXrayFromJson", json.RawMessage(`{"recordDiagnostics":true}`))
	if !flightrecorder.Enabled() {
		t.Fatal("proxy core did not record with the switch on")
	}
	if reply := call(`{"action":"mark"}`); !strings.Contains(reply, `"success":true`) {
		t.Fatalf("mark while recording: %s", reply)
	}
	_ = diagnosticsCommand(flightrecorder.Request{Action: "stop"})
	if reply := call(`{"action":"mark"}`); !strings.Contains(reply, `"success":true`) || flightrecorder.Enabled() {
		t.Fatalf("mark from a one-shot core: %s", reply)
	}
	if reply := call(`{"action":"export","destination":` + jsonString(destination) + `}`); !strings.Contains(reply, `"success":true`) {
		t.Fatalf("export: %s", reply)
	}
	z, err := zip.OpenReader(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	var marks, hosts int
	for _, file := range z.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(reader)
		reader.Close()
		marks += strings.Count(string(data), "user_stall_marker")
		if strings.HasPrefix(file.Name, "rvdiag-host-") {
			hosts++
		}
	}
	if marks != 2 || hosts != 1 {
		t.Fatalf("export has %d marks, %d host files", marks, hosts)
	}
}

func jsonString(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
