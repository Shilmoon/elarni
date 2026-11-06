package tun

import (
	"context"
	"io"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
)

// udpQueueLimit is the most datagrams a flow holds for its outbound before it drops new ones.
const udpQueueLimit = 1024

// packetQueue holds a flow's datagrams until its one reader takes them. It takes memory only for
// datagrams that wait (Elarni): a channel allocated all 1024 slots (8 KiB) for every flow up front.
type packetQueue struct {
	mu      sync.Mutex
	packets []*buf.Buffer
	head    int
	closed  bool
	ready   chan struct{} // wakes a reader waiting for a datagram
}

// push queues b; it fails once the queue is closed or full.
func (q *packetQueue) push(b *buf.Buffer) bool {
	q.mu.Lock()
	if q.closed || len(q.packets)-q.head >= udpQueueLimit {
		q.mu.Unlock()
		return false
	}
	if q.head > 0 && len(q.packets) == cap(q.packets) {
		n := copy(q.packets, q.packets[q.head:])
		clear(q.packets[n:])
		q.packets, q.head = q.packets[:n], 0
	}
	q.packets = append(q.packets, b)
	ready := q.ready
	q.mu.Unlock()
	wake(ready)
	return true
}

// pop returns the oldest datagram, waiting for one; it returns nil once the queue is closed and empty.
func (q *packetQueue) pop() *buf.Buffer {
	for {
		q.mu.Lock()
		if q.head < len(q.packets) {
			b := q.packets[q.head]
			q.packets[q.head] = nil
			if q.head++; q.head == len(q.packets) {
				q.packets, q.head = q.packets[:0], 0
			}
			q.mu.Unlock()
			return b
		}
		if q.closed {
			q.mu.Unlock()
			return nil
		}
		if q.ready == nil {
			q.ready = make(chan struct{}, 1)
		}
		ready := q.ready
		q.mu.Unlock()
		<-ready
	}
}

// close ends the queue; its reader still gets the datagrams queued before.
func (q *packetQueue) close() {
	q.mu.Lock()
	q.closed = true
	ready := q.ready
	q.mu.Unlock()
	wake(ready)
}

func wake(ready chan struct{}) {
	select {
	case ready <- struct{}{}:
	default:
	}
}

// udpFlowKey binds a flow to its app socket, so replies from any peer reach the app (full cone). A DNS
// datagram's flow also keys on its server (Elarni): routing hijacks port 53 to the DNS outbound, which drops
// anything else, so one socket's DNS and other traffic must not follow whichever came first.
type udpFlowKey struct{ src, dns net.Destination }

func flowKey(src, dst net.Destination) udpFlowKey {
	if dst.Port == 53 {
		return udpFlowKey{src, dst}
	}
	return udpFlowKey{src: src}
}

// sub-handler specifically for udp connections under main handler
type udpConnectionHandler struct {
	sync.RWMutex

	udpConns map[udpFlowKey]*udpConn
	closed   bool

	handleConnection func(conn net.Conn, dest net.Destination)
	writePacket      func(data []byte, src net.Destination, dst net.Destination) error
}

func newUdpConnectionHandler(handleConnection func(conn net.Conn, dest net.Destination), writePacket func(data []byte, src net.Destination, dst net.Destination) error) *udpConnectionHandler {
	handler := &udpConnectionHandler{
		udpConns:         make(map[udpFlowKey]*udpConn),
		handleConnection: handleConnection,
		writePacket:      writePacket,
	}

	return handler
}

// HandlePacket hands a datagram from tun, which it takes ownership of, to its flow.
// this custom handler support FullCone NAT of returning packets, binding connection only by the source addr:port
func (u *udpConnectionHandler) HandlePacket(src net.Destination, dst net.Destination, b *buf.Buffer) {
	b.UDP = &dst
	key := flowKey(src, dst)
	u.RLock()
	if u.closed {
		u.RUnlock()
		b.Release()
		return
	}
	conn, found := u.udpConns[key]
	if found {
		queued, retired := conn.enqueue(b)
		if !retired {
			if !queued {
				errors.LogDebug(context.Background(), "drop udp with size ", b.Len(), " to ", dst.NetAddr(), " original ", conn.dst.NetAddr(), " > queue full")
				b.Release()
			}
			u.RUnlock()
			return
		}
	}
	u.RUnlock()

	u.Lock()
	defer u.Unlock()
	if u.closed {
		b.Release()
		return
	}

	for {
		conn, found = u.udpConns[key]
		if !found {
			conn = &udpConn{handler: u, key: key, src: src, dst: dst}
			if dst.Port == 53 {
				conn.done, conn.retire = conn.answered, conn.retireAnswered
			}
			u.udpConns[key] = conn
		}
		// send packet data to the egress queue, if it has room, or discard
		queued, retired := conn.enqueue(b)
		if retired {
			// Admission replaced this flow and its session is ending: the datagram starts a new one (Elarni).
			delete(u.udpConns, key)
			conn.egress.close()
			continue
		}
		if !queued {
			errors.LogDebug(context.Background(), "drop udp with size ", b.Len(), " to ", dst.NetAddr(), " original ", conn.dst.NetAddr(), " > queue full 2")
			b.Release()
		}
		if !found {
			// Started after its first datagram is queued and counted, so admission never takes it for answered.
			go u.handleConnection(conn, dst)
		}
		return
	}
}

func (u *udpConnectionHandler) Close() {
	u.Lock()
	defer u.Unlock()
	u.closed = true
	for key, conn := range u.udpConns {
		delete(u.udpConns, key)
		conn.egress.close()
	}
}

func (u *udpConnectionHandler) connectionFinished(conn *udpConn) {
	u.Lock()
	if u.udpConns[conn.key] == conn {
		delete(u.udpConns, conn.key)
		conn.egress.close()
	}
	u.Unlock()
}

// udp connection abstraction
type udpConn struct {
	activity
	handler *udpConnectionHandler

	egress packetQueue
	key    udpFlowKey
	src    net.Destination
	dst    net.Destination
	// datagrams from the app minus datagrams back to it; a DNS flow at zero has every query answered
	unanswered atomic.Int64
}

// retiredFlow in unanswered marks a flow admission replaced; it takes no more datagrams.
const retiredFlow = math.MinInt64 / 2

func (c *udpConn) answered() bool { return c.unanswered.Load() <= 0 }

// retire claims the flow for replacement while every query has its answer (Elarni).
func (c *udpConn) retireAnswered() bool { return c.unanswered.CompareAndSwap(0, retiredFlow) }

// answer counts n datagrams back to the app; extra replies (duplicates, forged answers) never count
// for queries the app sends later.
func (c *udpConn) answer(n int64) {
	for {
		old := c.unanswered.Load()
		if old <= 0 || c.unanswered.CompareAndSwap(old, max(old-n, 0)) {
			return
		}
	}
}

// enqueue hands a datagram from the app to the flow; queued is false when the queue is full, and retired
// when admission replaced the flow, which then takes nothing.
func (c *udpConn) enqueue(b *buf.Buffer) (queued, retired bool) {
	for {
		n := c.unanswered.Load()
		if n < 0 {
			return false, true
		}
		if c.unanswered.CompareAndSwap(n, n+1) {
			break
		}
	}
	if c.egress.push(b) {
		return true, false
	}
	c.unanswered.Add(-1)
	return false, false
}

func (c *udpConn) ReadMultiBuffer() (buf.MultiBuffer, error) {
	b := c.egress.pop()
	if b == nil {
		return nil, io.EOF
	}
	c.touch()
	return buf.MultiBuffer{b}, nil
}

// Read packets from the connection
func (c *udpConn) Read(p []byte) (int, error) {
	b := c.egress.pop()
	if b == nil {
		return 0, io.EOF
	}
	defer b.Release()
	c.touch()
	n := copy(p, b.Bytes())
	if n != int(b.Len()) {
		return 0, io.ErrShortBuffer
	}
	return n, nil
}

func (c *udpConn) WriteMultiBuffer(mb buf.MultiBuffer) error {
	c.touch()
	c.answer(int64(len(mb)))
	for i, b := range mb {
		dst := c.dst
		if b.UDP != nil {
			if b.UDP.Address.Family().IsDomain() {
				errors.LogError(context.Background(), "impossible domain packet ", b.UDP, " reply via original target ", dst)
			} else {
				dst = *b.UDP
			}
		}
		err := c.handler.writePacket(b.Bytes(), dst, c.src)
		if err != nil {
			buf.ReleaseMulti(mb[i:])
			return err
		}
		b.Release()
	}
	return nil
}

// Write returning packets back
func (c *udpConn) Write(p []byte) (int, error) {
	// sending packets back mean sending payload with source/destination reversed
	c.touch()
	c.answer(1)
	err := c.handler.writePacket(p, c.dst, c.src)
	if err != nil {
		return 0, err
	}

	return len(p), nil
}

func (c *udpConn) Close() error {
	c.handler.connectionFinished(c)

	return nil
}

func (c *udpConn) LocalAddr() net.Addr {
	return c.dst.RawNetAddr()
}

func (c *udpConn) RemoteAddr() net.Addr {
	return c.src.RawNetAddr()
}

func (c *udpConn) SetDeadline(t time.Time) error {
	return nil
}

func (c *udpConn) SetReadDeadline(t time.Time) error {
	return nil
}

func (c *udpConn) SetWriteDeadline(t time.Time) error {
	return nil
}
