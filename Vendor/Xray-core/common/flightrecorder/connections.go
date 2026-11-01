//go:build elarni_recording || elarni_diagnostics

package flightrecorder

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type connectionKey struct{}

func WithConnection(ctx context.Context, id uint64) context.Context {
	return context.WithValue(ctx, connectionKey{}, id)
}
func Connection(ctx context.Context) uint64 {
	id, _ := ctx.Value(connectionKey{}).(uint64)
	return id
}

var connections sync.Map

type measuredConn struct {
	net.Conn
	*connectionProgress
}

type measuredPacketConn struct {
	net.PacketConn
	*connectionProgress
}

type connectionProgress struct {
	id, parent                         uint64
	session                            uint32
	kind                               string
	start                              time.Time
	read, written, lastRead, lastWrite atomic.Int64
	reading, writing                   atomic.Int64
	readOps, writeOps, sampledOps      atomic.Int64
	closed                             atomic.Bool
}

// TrackConn counts bytes and pending I/O, never addresses or payload contents.
func TrackConn(conn net.Conn, parent uint64, session uint32, kind string) net.Conn {
	if active.Load() == nil {
		return conn
	}
	return &measuredConn{Conn: conn, connectionProgress: trackConnection(parent, session, kind)}
}

// TrackPacketConn observes the datagram boundary without recording addresses or payloads.
func TrackPacketConn(conn net.PacketConn, parent uint64, session uint32, kind string) net.PacketConn {
	if active.Load() == nil {
		return conn
	}
	return &measuredPacketConn{PacketConn: conn, connectionProgress: trackConnection(parent, session, kind)}
}

func trackConnection(parent uint64, session uint32, kind string) *connectionProgress {
	c := &connectionProgress{id: NextID(), parent: parent, session: session, kind: kind, start: time.Now()}
	connections.Store(c.id, c)
	c.emit("opened", nil)
	return c
}

func (c *measuredConn) Read(p []byte) (int, error) {
	c.reading.Add(1)
	n, err := c.Conn.Read(p)
	c.readDone(n, err)
	return n, err
}

func (c *connectionProgress) readDone(n int, err error) {
	c.reading.Add(-1)
	if n > 0 || err == nil {
		c.readOps.Add(1)
	}
	if n > 0 {
		c.read.Add(int64(n))
		c.lastRead.Store(time.Since(c.start).Milliseconds())
	}
	if err != nil {
		c.emit("read_done", err)
	}
}
func (c *measuredConn) Write(p []byte) (int, error) {
	c.writing.Add(1)
	n, err := c.Conn.Write(p)
	c.writeDone(n, err)
	return n, err
}

func (c *connectionProgress) writeDone(n int, err error) {
	c.writing.Add(-1)
	if n > 0 || err == nil {
		c.writeOps.Add(1)
	}
	if n > 0 {
		c.written.Add(int64(n))
		c.lastWrite.Store(time.Since(c.start).Milliseconds())
	}
	if err != nil {
		c.emit("write_done", err)
	}
}
func (c *measuredConn) Close() error {
	err := c.Conn.Close()
	c.closeDone(err)
	return err
}
func (c *measuredPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	c.reading.Add(1)
	n, addr, err := c.PacketConn.ReadFrom(p)
	c.readDone(n, err)
	return n, addr, err
}
func (c *measuredPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	c.writing.Add(1)
	n, err := c.PacketConn.WriteTo(p, addr)
	c.writeDone(n, err)
	return n, err
}
func (c *measuredPacketConn) Close() error {
	err := c.PacketConn.Close()
	c.closeDone(err)
	return err
}
func (c *connectionProgress) closeDone(err error) {
	if c.closed.CompareAndSwap(false, true) {
		connections.Delete(c.id)
		c.emit("closed", err)
	}
}
func (c *connectionProgress) emit(stage string, err error) {
	code := "ok"
	if err != nil {
		code = "failed"
		var ne net.Error
		switch {
		case errors.Is(err, context.Canceled):
			code = "canceled"
		case errors.Is(err, io.EOF):
			code = "eof"
		case errors.Is(err, net.ErrClosed), errors.Is(err, io.ErrClosedPipe):
			code = "closed"
		case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
			code = "timeout"
		}
	}
	age := time.Since(c.start).Milliseconds()
	Record(Event{Name: c.kind + "_" + stage, Code: code, Connection: c.id, Session: c.session, Values: map[string]int64{
		"parent": int64(c.parent), "age_ms": age, "read_bytes": c.read.Load(), "written_bytes": c.written.Load(),
		"read_idle_ms": age - c.lastRead.Load(), "write_idle_ms": age - c.lastWrite.Load(),
		"pending_reads": c.reading.Load(), "pending_writes": c.writing.Load(),
		"read_ops": c.readOps.Load(), "write_ops": c.writeOps.Load(),
	}})
}

// sampleConnections reports connections that moved data or are blocked writing; with all set, every
// open one. Idle ones are otherwise skipped, and read_idle_ms covers the gap on their next line.
func sampleConnections(all bool) {
	connections.Range(func(_, value any) bool {
		c := value.(*connectionProgress)
		ops := c.readOps.Load() + c.writeOps.Load()
		if c.sampledOps.Swap(ops) != ops || c.writing.Load() > 0 || all {
			c.emit("progress", nil)
		}
		return true
	})
}
