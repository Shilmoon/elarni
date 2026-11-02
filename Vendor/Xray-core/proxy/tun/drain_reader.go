package tun

import (
	"io"

	"github.com/xtls/xray-core/common/buf"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/waiter"
)

// Elarni: read one buffer at a time, an upload reached the outbound as one write syscall per
// 8 KiB; taking what the stack already holds lets the outbound write it at once.
type drainReader struct {
	io.Reader
	ready func() bool // the stack holds more bytes, so a Read does not block
}

func (r *drainReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	b, err := buf.ReadBuffer(r.Reader)
	if b == nil {
		return nil, err
	}
	mb := buf.MultiBuffer{b}
	for err == nil && b.IsFull() && len(mb) < 8 && r.ready() {
		if b, err = buf.ReadBuffer(r.Reader); b != nil {
			mb = append(mb, b)
		}
	}
	return mb, err
}

// tcpConn lets HandleConnection see whether the stack holds unread bytes.
type tcpConn struct {
	*gonet.TCPConn
	ep tcpip.Endpoint
}

func (c *tcpConn) readable() bool {
	return c.ep.Readiness(waiter.ReadableEvents) != 0
}
