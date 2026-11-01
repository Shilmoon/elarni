package websocket

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	ws "github.com/gorilla/websocket"
)

// Imported-client traffic catches dropped responses. This boundary regression
// additionally distinguishes normal stream completion from an abnormal peer
// close, which successful traffic cannot establish.
func TestPeerClosePreservesStreamCompletion(t *testing.T) {
	for _, code := range []int{ws.CloseNormalClosure, ws.ClosePolicyViolation} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			payload := bytes.Repeat([]byte("synthetic-close-response"), 256)
			peer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&ws.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				if err := conn.WriteMessage(ws.BinaryMessage, payload); err != nil {
					return
				}
				conn.WriteControl(ws.CloseMessage, ws.FormatCloseMessage(code, "fixture"), time.Now().Add(time.Second))
			}))
			defer peer.Close()
			conn, _, err := ws.DefaultDialer.Dial("ws"+strings.TrimPrefix(peer.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			conn.SetReadDeadline(time.Now().Add(time.Second))
			response, err := io.ReadAll(NewConnection(conn, conn.RemoteAddr(), nil, 0))
			if !bytes.Equal(response, payload) {
				t.Fatal("response truncated on peer close")
			}
			if code == ws.CloseNormalClosure && err != nil {
				t.Fatalf("normal close must complete the stream: %v", err)
			}
			if code != ws.CloseNormalClosure && !ws.IsCloseError(err, code) {
				t.Fatalf("abnormal close lost its error: %v", err)
			}
		})
	}
}
