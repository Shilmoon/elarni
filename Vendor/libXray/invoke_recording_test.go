//go:build elarni_recording || elarni_diagnostics

package libXray

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestEmptyRecordingExportReturnsItsCode(t *testing.T) {
	directory := t.TempDir()
	request, err := json.Marshal(map[string]any{"apiVersion": 1, "method": "diagnostics", "payload": map[string]any{
		"action": "export", "directory": directory, "destination": filepath.Join(t.TempDir(), "recording.zip"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		Success bool   `json:"success"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal([]byte(Invoke(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if response.Success || response.Error != "recording_empty" {
		t.Fatalf("empty export = %+v", response)
	}
}
