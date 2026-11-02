package tun

import (
	"bytes"
	"testing"

	"github.com/xtls/xray-core/common/buf"
)

type recordingWriter struct{ writes [][]byte }

func (w *recordingWriter) Write(b []byte) (int, error) {
	w.writes = append(w.writes, bytes.Clone(b))
	return len(b), nil
}

// At a 9000-byte MTU the MSS exceeds Xray's 8 KiB buffers: written one by one,
// every buffer would leave the TUN as its own packet and no segment offload
// could merge them.
func TestTCPWriterHandsTheStackWholeMultiBuffers(t *testing.T) {
	var want []byte
	var mb buf.MultiBuffer
	for i := range 20 {
		b := buf.New()
		b.Extend(buf.Size)
		for j := range b.Bytes() {
			b.Bytes()[j] = byte(i + j)
		}
		want = append(want, b.Bytes()...)
		mb = append(mb, b)
	}
	conn := &recordingWriter{}
	if err := newTCPWriter(conn).WriteMultiBuffer(mb); err != nil {
		t.Fatal(err)
	}
	if len(conn.writes) != 3 || len(conn.writes[0]) != tcpWriteSize {
		sizes := []int{}
		for _, w := range conn.writes {
			sizes = append(sizes, len(w))
		}
		t.Fatalf("160 KiB arrived in writes of %v bytes", sizes)
	}
	if !bytes.Equal(bytes.Join(conn.writes, nil), want) {
		t.Fatal("bytes changed on the way")
	}
}
