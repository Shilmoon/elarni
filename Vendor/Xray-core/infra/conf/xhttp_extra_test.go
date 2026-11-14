package conf

import (
	"encoding/json"
	"testing"

	"github.com/xtls/xray-core/transport/internet/splithttp"
)

// A profile written back by a client carries the unset "extra" as null, which is no extra:
// the settings beside it must stay.
func TestXHTTPNullExtraKeepsTheSettingsBesideIt(t *testing.T) {
	var settings SplitHTTPConfig
	if err := json.Unmarshal([]byte(`{"path":"/down","xPaddingBytes":"5-9","noGRPCHeader":true,"extra":null}`), &settings); err != nil {
		t.Fatal(err)
	}
	built, err := settings.Build()
	if err != nil {
		t.Fatal(err)
	}
	config := built.(*splithttp.Config)
	if config.XPaddingBytes.GetFrom() != 5 || config.XPaddingBytes.GetTo() != 9 || !config.NoGRPCHeader {
		t.Errorf("settings %v", config)
	}
}
