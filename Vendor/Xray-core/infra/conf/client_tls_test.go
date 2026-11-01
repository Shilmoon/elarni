package conf_test

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/xtls/xray-core/infra/conf"
	xraytls "github.com/xtls/xray-core/transport/internet/tls"
)

func TestClientTLSVerificationPolicies(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer server.Close()
	pin := sha256.Sum256(server.Certificate().Raw)
	wrongPin := sha256.Sum256([]byte("different certificate"))
	for _, fixture := range []struct {
		name     string
		config   conf.TLSConfig
		succeeds bool
	}{
		{"default rejects untrusted server", conf.TLSConfig{}, false},
		{"provider explicit insecure opt out", conf.TLSConfig{AllowInsecure: true}, true},
		{"correct certificate pin", conf.TLSConfig{PinnedPeerCertSha256: hex.EncodeToString(pin[:])}, true},
		{"pin remains enforced with insecure flag", conf.TLSConfig{AllowInsecure: true, PinnedPeerCertSha256: hex.EncodeToString(wrongPin[:])}, false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			built, err := fixture.config.Build()
			if err != nil {
				t.Fatal(err)
			}
			transport := &http.Transport{TLSClientConfig: built.(*xraytls.Config).GetTLSConfig()}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
			response, err := client.Get(server.URL)
			if (err == nil) != fixture.succeeds {
				t.Fatalf("TLS outcome: got success=%t, expected=%t", err == nil, fixture.succeeds)
			}
			if response != nil {
				io.Copy(io.Discard, response.Body)
				response.Body.Close()
				if response.StatusCode != 204 {
					t.Fatal("wrong HTTP response")
				}
			}
		})
	}
}
