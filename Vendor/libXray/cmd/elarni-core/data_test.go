package main

import (
	"encoding/base64"
	"github.com/xtls/libxray/share"
	"testing"
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
