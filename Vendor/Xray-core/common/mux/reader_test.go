package mux_test

import (
	"bytes"
	"io"
	"testing"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/mux"
	"github.com/xtls/xray-core/common/net"
)

// XUDP frames carry up to 65535 bytes; a large one must not end the connection.
func TestPacketReaderReadsLargeFrameWhole(t *testing.T) {
	payload := bytes.Repeat([]byte{0x5a}, 20000)
	dest := net.UDPDestination(net.LocalHostIP, 53)
	reader := mux.NewPacketReader(bytes.NewReader(append([]byte{0x4e, 0x20}, payload...)), &dest)
	mb, err := reader.ReadMultiBuffer()
	if err != nil || len(mb) != 1 || mb[0].Len() != 20000 || mb[0].UDP == nil || *mb[0].UDP != dest || !bytes.Equal(mb[0].Bytes(), payload) {
		t.Fatalf("large frame: %d buffers, %d bytes, %v", len(mb), mb.Len(), err)
	}
	buf.ReleaseMulti(mb)
	if _, err := reader.ReadMultiBuffer(); err != io.EOF {
		t.Fatalf("second read: %v", err)
	}
	short := mux.NewPacketReader(bytes.NewReader([]byte{0x00, 0x10, 1, 2}), &dest)
	if _, err := short.ReadMultiBuffer(); err == nil {
		t.Fatal("truncated frame accepted")
	}
}
