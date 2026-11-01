//go:build !elarni_recording && !elarni_diagnostics

package flightrecorder

import (
	"encoding/json"
	"testing"
)

func TestNormalBuildHasNoCollector(t *testing.T) {
	status, err := Command(json.RawMessage(`{"action":"status"}`))
	if err != nil || status.(map[string]any)["enabled"] != false {
		t.Fatal("incorrect disabled status")
	}
	for _, action := range []string{"start", "mark", "flush", "stop", "export"} {
		data, _ := json.Marshal(Request{Action: action, Directory: t.TempDir(), Destination: t.TempDir() + "/export.zip", Role: "helper"})
		if _, err := Command(data); err == nil {
			t.Fatalf("normal build accepted %s", action)
		}
	}
	if Enabled() {
		t.Fatal("collector enabled in a normal build")
	}
}
