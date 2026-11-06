package main

import (
	"encoding/base64"
	"net/netip"
	"slices"
	"testing"

	"github.com/xtls/libxray/share"
)

// These generated masks previously confused the camera-oriented finder scan.
// A QR exported by Elarni must remain importable without a camera transform.
func TestGeneratedQRSubscriptionRoundTrip(t *testing.T) {
	for _, text := range []string{
		"http://127.0.0.1:40045/sub/token?key=a%2Bb%23c#QR%20subscription",
		"http://127.0.0.1:40049/sub/token?key=a%2Bb%23c#QR%20subscription",
		"http://127.0.0.1:40055/sub/token?key=a%2Bb%23c#QR%20subscription",
	} {
		t.Run(text, func(t *testing.T) {
			encoded, err := share.ClientQR(text)
			if err != nil {
				t.Fatal(err)
			}
			data, err := base64.StdEncoding.DecodeString(encoded["png"])
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := decodeQR(data)
			if err != nil || decoded != text {
				t.Fatalf("QR round trip = %q, %v; want %q", decoded, err, text)
			}
		})
	}
}

// Server tests while connected resolve through here; see the fetcher's systemLookup.
func TestLookupHostAnswersAddresses(t *testing.T) {
	data, err, handled := dataRequest("lookupHost", []byte(`{"host":"localhost"}`))
	if !handled || err != nil || !slices.Contains(data.(map[string]any)["addresses"].([]netip.Addr), netip.MustParseAddr("127.0.0.1")) {
		t.Fatalf("lookupHost localhost = %v, %v", data, err)
	}
	if _, err, _ := dataRequest("lookupHost", []byte(`{"host":""}`)); err == nil || err.Error() != "invalid_request" {
		t.Fatalf("empty host: %v", err)
	}
}
