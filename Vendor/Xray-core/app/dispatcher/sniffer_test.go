package dispatcher

import (
	"context"
	"testing"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/pipe"
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

// A client of a server-first protocol sends nothing, so sniffing it waited the full 200 ms
// before the outbound was even dialed, and the server's greeting with it.
func TestServerFirstPortsSkipTheSniffWait(t *testing.T) {
	instance, err := core.New(&core.Config{})
	common.Must(err)
	ctx := context.WithValue(context.Background(), core.XrayKey(1), instance)
	for _, c := range []struct {
		dest net.Destination
		wait bool
	}{
		{net.TCPDestination(net.LocalHostIP, 25), false},
		{net.TCPDestination(net.LocalHostIP, 3306), false},
		{net.TCPDestination(net.LocalHostIP, 443), true},
		{net.UDPDestination(net.LocalHostIP, 25), true},
	} {
		reader, writer := pipe.New(pipe.WithoutSizeLimit())
		start := time.Now()
		_, err := sniffer(ctx, &cachedReader{reader: reader}, false, c.dest)
		waited := time.Since(start) >= 150*time.Millisecond
		writer.Close()
		if err == nil || waited != c.wait {
			t.Errorf("%v: waited %v (want %v), err %v", c.dest, waited, c.wait, err)
		}
	}
}
