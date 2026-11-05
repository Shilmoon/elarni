package socks

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/signal"
)

func NewTempUDPConn(udpConn net.PacketConn, tcpConn net.Conn, expectedRemote *net.UDPAddr) *TempUDPConn {
	t := &TempUDPConn{
		PacketConn:        udpConn,
		AssociatedTCPConn: tcpConn,
	}
	t.Timer = signal.CancelAfterInactivity(context.Background(), func() {
		t.Close()
	}, net.ConnIdleTimeout)
	t.ExpectedRemote.Store(expectedRemote)
	return t
}

// TempUDPConn wait for the first packet to determine the remote address
// SetTimeout MUST be called before any read/write operation
type TempUDPConn struct {
	net.PacketConn
	AssociatedTCPConn net.Conn
	ExpectedRemote    atomic.Pointer[net.UDPAddr]
	Timer             *signal.ActivityTimer
	scratch           []byte
}

func (c *TempUDPConn) Read(b []byte) (n int, err error) {
	var remote net.Addr
	for {
		n, remote, err = c.PacketConn.ReadFrom(b)
		if err != nil {
			return
		}
		if c.fromClient(remote) {
			return
		}
	}
}

// ReadMultiBuffer reads the client's next datagram (Elarni): on Unix and Windows a pooled buffer is borrowed only
// while one is ready, where a reader over Read kept 64 KiB for each association.
func (c *TempUDPConn) ReadMultiBuffer() (buf.MultiBuffer, error) {
	for {
		b, remote, err := buf.ReadPacketFrom(c.PacketConn, &c.scratch)
		if err != nil {
			return nil, err
		}
		if c.fromClient(remote) {
			return buf.MultiBuffer{b}, nil
		}
		b.Release()
	}
}

// fromClient reports whether a datagram came from the associated client, learning its port if unknown.
func (c *TempUDPConn) fromClient(addr net.Addr) bool {
	remote, ok := addr.(*net.UDPAddr)
	if !ok {
		return false
	}
	expected := c.ExpectedRemote.Load()
	if !remote.IP.Equal(expected.IP) {
		return false
	}
	if remote.Port != expected.Port {
		if expected.Port != 0 {
			return false
		}
		c.ExpectedRemote.Store(remote)
	}
	c.Timer.Update()
	return true
}

func (c *TempUDPConn) Write(b []byte) (n int, err error) {
	c.Timer.Update()
	return c.PacketConn.WriteTo(b, c.ExpectedRemote.Load())
}

func (c *TempUDPConn) RemoteAddr() net.Addr {
	return c.ExpectedRemote.Load()
}

func (c *TempUDPConn) SetTimeout(d time.Duration) {
	c.Timer.SetTimeout(d)
}

func (c *TempUDPConn) Close() error {
	if c.Timer != nil {
		c.Timer.SetTimeout(0)
	}
	c.AssociatedTCPConn.Close()
	return c.PacketConn.Close()
}
