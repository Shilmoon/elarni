package tun

import (
	"io"
	"sync"

	"github.com/xtls/xray-core/common/buf"
)

// tcpWriteSize is the most one write hands the stack: its largest offloaded segment.
const tcpWriteSize = 64 << 10

// tcpScratch holds exactly tcpWriteSize (Elarni): bytespool's next size up is 128 KiB.
var tcpScratch = sync.Pool{New: func() any { return new([tcpWriteSize]byte) }}

// tcpWriter writes each MultiBuffer to a TUN connection in writes of up to 64 KiB.
// Written one by one, Xray's 8 KiB buffers would each leave as their own segment,
// below the MSS of a 9000-byte TUN MTU, so segment offload had nothing to merge.
type tcpWriter struct {
	io.Writer
	closeWrite func() error
}

func newTCPWriter(w io.Writer, closeWrite func() error) buf.Writer {
	return &tcpWriter{Writer: w, closeWrite: closeWrite}
}

func (w *tcpWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	defer buf.ReleaseMulti(mb)
	if len(mb) == 1 {
		return buf.WriteAllBytes(w.Writer, mb[0].Bytes(), nil)
	}
	scratch := tcpScratch.Get().(*[tcpWriteSize]byte)
	defer tcpScratch.Put(scratch)
	for !mb.IsEmpty() {
		var n int
		mb, n = buf.SplitBytes(mb, scratch[:])
		if err := buf.WriteAllBytes(w.Writer, scratch[:n], nil); err != nil {
			return err
		}
	}
	return nil
}

// Close sends the app a FIN once the response has ended (Elarni): before, the app saw it only when the
// whole session closed, after policy uplinkOnly.
func (w *tcpWriter) Close() error {
	return w.closeWrite()
}
