package buf_test

import (
	"bytes"
	"testing"

	"github.com/xtls/xray-core/common/buf"
)

// A write larger than the free buffer space flushes and continues. The Trojan
// client writes its request header and then the first payload this way.
func TestBufferedWriterSpillsLargeWrite(t *testing.T) {
	var out bytes.Buffer
	w := buf.NewBufferedWriter(buf.NewWriter(&out))
	header := []byte("header")
	payload := bytes.Repeat([]byte{7}, buf.Size)
	if _, err := w.Write(header); err != nil {
		t.Fatal(err)
	}
	if n, err := w.Write(payload); err != nil || n != len(payload) {
		t.Fatalf("Write(%d bytes) = %d, %v", len(payload), n, err)
	}
	if err := w.SetBuffered(false); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Bytes(), append(header, payload...)) {
		t.Fatalf("wrote %d bytes, want %d", out.Len(), len(header)+len(payload))
	}
}
