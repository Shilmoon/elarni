package conf_test

import (
	"encoding/json"
	"testing"

	"github.com/xtls/xray-core/infra/conf"
)

// Subscription profiles are untrusted: a null DNS entry must fail the build, not crash the core.
func TestNullDNSEntriesFailTheBuild(t *testing.T) {
	for name, section := range map[string]string{
		"server without address": `"dns":{"servers":[{"tag":"x"}]}`,
		"null server":            `"dns":{"servers":[null]}`,
		"null host":              `"dns":{"servers":["1.1.1.1"],"hosts":{"a.example":null}}`,
		"null host address":      `"dns":{"servers":["1.1.1.1"],"hosts":{"a.example":["1.1.1.1",null]}}`,
		"null fakedns pool":      `"dns":{"servers":["fakedns"]},"fakeDns":[null]`,
	} {
		t.Run(name, func(t *testing.T) {
			var config conf.Config
			if err := json.Unmarshal([]byte(`{`+section+`,"outbounds":[{"protocol":"freedom"}]}`), &config); err != nil {
				t.Fatal(err)
			}
			if _, err := config.Build(); err == nil {
				t.Fatal("built a config with a null DNS entry")
			}
		})
	}
}
