package dispatcher

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/net"
)

// A short first payload that no sniffer can match waited 200 ms for more data, which
// delayed every connection of protocols that start with a few bytes.
func TestShortPayloadsThatMatchNoProtocolEndSniffingAtOnce(t *testing.T) {
	for _, payload := range []string{"!", "PING\r\n", "\x00\x01"} {
		if _, err := (&Sniffer{sniffer: contentSniffers()}).Sniff(context.Background(), []byte(payload), net.Network_TCP); err != errUnknownContent {
			t.Errorf("%q: %v, want %v", payload, err, errUnknownContent)
		}
	}
	for _, payload := range []string{"\x00\x01", "\x40\x00"} {
		if _, err := (&Sniffer{sniffer: contentSniffers()}).Sniff(context.Background(), []byte(payload), net.Network_UDP); err != errUnknownContent {
			t.Errorf("UDP %q: %v, want %v", payload, err, errUnknownContent)
		}
	}
	// A prefix that can still become a request or handshake keeps waiting.
	for _, payload := range []string{"GE", "OPTIO", "\x16\x03", "\x13Bit"} {
		if _, err := (&Sniffer{sniffer: contentSniffers()}).Sniff(context.Background(), []byte(payload), net.Network_TCP); err != common.ErrNoClue {
			t.Errorf("%q: %v, want %v", payload, err, common.ErrNoClue)
		}
	}
	result, err := (&Sniffer{sniffer: contentSniffers()}).Sniff(context.Background(), []byte("get / HTTP/1.1\r\nHost: example.com\r\n\r\n"), net.Network_TCP)
	if err != nil || result.Domain() != "example.com" {
		t.Errorf("HTTP request sniffed as %v, %v", result, err)
	}
	result, err = (&Sniffer{sniffer: contentSniffers()}).Sniff(context.Background(), []byte("\x13BitTorrent protocol\x00"), net.Network_TCP)
	if err != nil || result.Protocol() != "bittorrent" {
		t.Errorf("BitTorrent handshake sniffed as %v, %v", result, err)
	}
}
