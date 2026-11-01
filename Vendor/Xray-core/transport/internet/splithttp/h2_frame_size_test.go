package splithttp

import (
	"bytes"
	"context"
	"io"
	gonet "net"
	"net/http"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

// Go's HTTP/2 server, and so Xray's XHTTP server, advertises 1 MB frames, and Go's client
// then gives each upload stream a 512 KiB buffer; 35 of them got iOS extensions killed at
// the 50 MB limit (Xray-core #6663). Uploads must use the spec minimum, 16 KiB.
func TestH2UploadsUseTheSpecMinimumFrameSize(t *testing.T) {
	listener, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	settled, largest := make(chan struct{}), make(chan int, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		if _, err := io.ReadFull(conn, make([]byte, len(http2.ClientPreface))); err != nil {
			return
		}
		framer := http2.NewFramer(conn, conn)
		framer.WriteSettings(http2.Setting{ID: http2.SettingMaxFrameSize, Val: 1 << 20},
			http2.Setting{ID: http2.SettingInitialWindowSize, Val: 1 << 22})
		framer.WriteWindowUpdate(0, 1<<22)
		biggest, total := 0, 0
		for total < 256<<10 {
			frame, err := framer.ReadFrame()
			if err != nil {
				break
			}
			switch f := frame.(type) {
			case *http2.SettingsFrame:
				if f.IsAck() {
					close(settled)
				} else {
					framer.WriteSettingsAck()
				}
			case *http2.DataFrame:
				biggest, total = max(biggest, len(f.Data())), total+len(f.Data())
			}
		}
		largest <- biggest
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	transport := h2Transport(func(ctx context.Context) (gonet.Conn, error) {
		var dialer gonet.Dialer
		return dialer.DialContext(ctx, "tcp", listener.Addr().String())
	}, 0)
	conn, err := transport.DialTLSContext(ctx, "tcp", listener.Addr().String(), nil)
	if err != nil {
		t.Fatal(err)
	}
	client, err := transport.NewClientConn(conn)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	// The client sizes a stream's buffer when its body starts, so it must have read the server's settings.
	select {
	case <-settled:
	case <-ctx.Done():
		t.Fatal("the client never acknowledged the server's settings")
	}
	// A stream-up upload: no Content-Length, so nothing but the frame size bounds the buffer.
	request, err := http.NewRequestWithContext(ctx, "POST", "https://"+listener.Addr().String()+"/up",
		io.NopCloser(bytes.NewReader(make([]byte, 256<<10))))
	if err != nil {
		t.Fatal(err)
	}
	go client.RoundTrip(request)
	select {
	case biggest := <-largest:
		if biggest > 16384 {
			t.Fatalf("the client sent %d-byte DATA frames, so each upload stream holds a buffer that large", biggest)
		}
	case <-ctx.Done():
		t.Fatal("the upload never reached the server")
	}
}

// Frames arrive split anywhere; only the SETTINGS_MAX_FRAME_SIZE values may change.
func TestMaxFrameClampSurvivesSplitReads(t *testing.T) {
	var sent bytes.Buffer
	framer := http2.NewFramer(&sent, nil)
	framer.WriteSettings(http2.Setting{ID: http2.SettingInitialWindowSize, Val: 1 << 20},
		http2.Setting{ID: http2.SettingMaxFrameSize, Val: 1 << 20},
		http2.Setting{ID: http2.SettingMaxConcurrentStreams, Val: 100})
	framer.WriteData(1, false, []byte{0, 0, 0x5, 0, 0x10, 0, 0, 0})
	framer.WriteSettingsAck()
	framer.WriteSettings(http2.Setting{ID: http2.SettingMaxFrameSize, Val: 1<<24 - 1})
	framer.WritePing(false, [8]byte{1, 2, 3, 4, 5, 6, 7, 8})

	server, client := gonet.Pipe()
	defer client.Close()
	go func() {
		defer server.Close()
		for _, b := range sent.Bytes() {
			if _, err := server.Write([]byte{b}); err != nil {
				return
			}
		}
	}()
	reader := http2.NewFramer(io.Discard, &maxFrameClamp{Conn: client})
	settings := func() map[http2.SettingID]uint32 {
		frame, err := reader.ReadFrame()
		if err != nil {
			t.Fatal(err)
		}
		values := map[http2.SettingID]uint32{}
		frame.(*http2.SettingsFrame).ForeachSetting(func(s http2.Setting) error {
			values[s.ID] = s.Val
			return nil
		})
		return values
	}
	if got := settings(); got[http2.SettingMaxFrameSize] != 16384 || got[http2.SettingInitialWindowSize] != 1<<20 || got[http2.SettingMaxConcurrentStreams] != 100 {
		t.Fatalf("first settings: %v", got)
	}
	frame, err := reader.ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	if data := frame.(*http2.DataFrame).Data(); !bytes.Equal(data, []byte{0, 0, 0x5, 0, 0x10, 0, 0, 0}) {
		t.Fatalf("a DATA payload that looks like a setting changed: %v", data)
	}
	if frame, err := reader.ReadFrame(); err != nil || !frame.(*http2.SettingsFrame).IsAck() {
		t.Fatalf("settings ack: %v %v", frame, err)
	}
	if got := settings(); got[http2.SettingMaxFrameSize] != 16384 {
		t.Fatalf("later settings: %v", got)
	}
	if frame, err := reader.ReadFrame(); err != nil || frame.(*http2.PingFrame).Data != [8]byte{1, 2, 3, 4, 5, 6, 7, 8} {
		t.Fatalf("ping: %v %v", frame, err)
	}
}
