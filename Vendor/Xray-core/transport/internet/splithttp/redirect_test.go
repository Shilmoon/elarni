package splithttp_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/splithttp"
)

// A front's redirect sends a post somewhere other than the XHTTP server, so
// it must fail the upload instead of counting as delivered.
func TestXHTTPRedirectedPostIsNotDelivered(t *testing.T) {
	var moved atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/moved":
			moved.Add(1)
			_, _ = io.Copy(io.Discard, r.Body)
		case r.Method == http.MethodGet:
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			_, _ = io.Copy(io.Discard, r.Body)
			http.Redirect(w, r, "/moved", http.StatusTemporaryRedirect)
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	digest := sha256.Sum256(server.Certificate().Raw)
	settings := xhttpFixtureConfig(t, map[string]any{"network": "xhttp", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.com", "alpn": []string{"h2"}, "pinnedPeerCertSha256": hex.EncodeToString(digest[:])}, "xhttpSettings": map[string]any{"mode": "packet-up", "path": "/fixture"}})
	defer internet.ReleaseTransport(settings)
	conn, err := splithttp.Dial(context.Background(), xhttpFixtureDest(server.Listener), settings)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(20 * time.Millisecond) {
		if _, err := conn.Write([]byte("payload")); err != nil {
			if n := moved.Load(); n != 0 {
				t.Fatalf("the redirect target received %d posts", n)
			}
			return
		}
	}
	t.Fatalf("redirected posts counted as delivered; the redirect target received %d", moved.Load())
}
