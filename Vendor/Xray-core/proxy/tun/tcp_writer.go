package tun

import (
	"io"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/bytespool"
)

// tcpWriteSize is the most one write hands the stack: its largest offloaded segment.
const tcpWriteSize = 64 << 10

// tcpWriter writes each MultiBuffer to a TUN connection in writes of up to 64 KiB.
// Written one by one, Xray's 8 KiB buffers would each leave as their own segment,
// below the MSS of a 9000-byte TUN MTU, so segment offload had nothing to merge.
type tcpWriter struct{ io.Writer }

func newTCPWriter(w io.Writer) buf.Writer { return &tcpWriter{Writer: w} }

func (w *tcpWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	defer buf.ReleaseMulti(mb)
	if len(mb) == 1 {
		return buf.WriteAllBytes(w.Writer, mb[0].Bytes(), nil)
	}
	scratch := bytespool.Alloc(tcpWriteSize)[:tcpWriteSize]
	defer bytespool.Free(scratch)
	for !mb.IsEmpty() {
		var n int
		mb, n = buf.SplitBytes(mb, scratch)
		if err := buf.WriteAllBytes(w.Writer, scratch[:n], nil); err != nil {
			return err
		}
	}
	return nil
}
