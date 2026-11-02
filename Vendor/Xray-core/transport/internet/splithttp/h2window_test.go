package splithttp

import (
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

// Go's default 4 MiB per-stream window let each stalled download hold about 4 MB;
// the transport advertises 2 MiB, as the WireGuard tunnel caps its TCP buffers.
func TestHTTP2DownloadsAdvertiseTwoMiBStreamWindows(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	transport := h2Transport(func(context.Context) (net.Conn, error) { return client, nil }, 0)
	defer transport.CloseIdleConnections()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://example.test/", nil)
		if response, err := transport.RoundTrip(request); err == nil {
			response.Body.Close()
		}
	}()
	server.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(server, make([]byte, len(http2.ClientPreface))); err != nil {
		t.Fatal(err)
	}
	frame, err := http2.NewFramer(io.Discard, server).ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	settings, ok := frame.(*http2.SettingsFrame)
	if !ok {
		t.Fatalf("first frame %v", frame)
	}
	if window, _ := settings.Value(http2.SettingInitialWindowSize); window != 2<<20 {
		t.Fatalf("stream window %d, want %d", window, 2<<20)
	}
}
