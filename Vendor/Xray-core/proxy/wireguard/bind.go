package wireguard

import (
	"context"
	goerrors "errors"
	"io"
	"net"
	"net/netip"
	"runtime"
	"strconv"
	"sync"
	"syscall"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
	"golang.org/x/net/ipv4"
	"golang.zx2c4.com/wireguard/conn"
)

// x/net moves a batch in one recvmmsg or sendmmsg only on Linux; elsewhere it would
// still make one system call per datagram.
var batchSyscalls = runtime.GOOS == "linux"

// batchConn returns the system UDP socket under c, possibly behind byte counters, for
// batched I/O. Masks and diagnostics wrappers keep the per-datagram path.
func batchConn(c net.PacketConn) (*ipv4.PacketConn, *PacketCounterConnection) {
	counter, _ := c.(*PacketCounterConnection)
	if counter != nil {
		c = counter.PacketConn
	}
	if udp, ok := c.(*net.UDPConn); ok && batchSyscalls {
		// Both families share the message format; Linux accepts IPv4 addresses on a dual-stack socket.
		return ipv4.NewPacketConn(udp), counter
	}
	return nil, nil
}

func newBatchMessages() []ipv4.Message {
	messages := make([]ipv4.Message, conn.IdealBatchSize)
	for i := range messages {
		messages[i].Buffers = make([][]byte, 1)
	}
	return messages
}

var batchMessages = sync.Pool{New: func() any { messages := newBatchMessages(); return &messages }}

type bind struct {
	resolveFunc    func(host string) (net.IP, error)
	listenFunc     func() (net.PacketConn, error)
	downFunc       func() error
	reserved       []byte
	preserveHeader bool

	net.PacketConn
	batch   *ipv4.PacketConn
	counter *PacketCounterConnection
	closeCh chan struct{}
	mu      sync.Mutex
}

func (b *bind) Open(port uint16) (fns []conn.ReceiveFunc, actualPort uint16, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.PacketConn != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}

	c, err := b.listenFunc()
	if err != nil {
		return nil, 0, err
	}
	b.PacketConn = c
	ch := make(chan struct{})
	b.closeCh = ch
	batch, counter := batchConn(c)
	var messages []ipv4.Message
	if batch != nil {
		b.batch, b.counter = batch, counter
		messages = newBatchMessages()
	}

	return []conn.ReceiveFunc{
		func(bufs [][]byte, sizes []int, eps []conn.Endpoint) (n int, err error) {
			for {
				var addr net.Addr
				n = 1
				if batch != nil {
					n = min(len(bufs), len(messages))
					for i := range n {
						messages[i].Buffers[0] = bufs[i]
					}
					n, err = batch.ReadBatch(messages[:n], 0)
				} else {
					sizes[0], addr, err = c.ReadFrom(bufs[0])
				}
				if err != nil {
					if goerrors.Is(err, io.EOF) || goerrors.Is(err, io.ErrClosedPipe) || goerrors.Is(err, net.ErrClosed) {
						select {
						case <-ch:
						default:
							errors.LogErrorInner(context.Background(), err, "unexpected closed")
							if b.downFunc != nil {
								go func() {
									common.Must(b.downFunc())
								}()
							}
						}
						return 0, net.ErrClosed
					}
					errors.LogErrorInner(context.Background(), err, "bind recv err")
					continue
				}
				for i := range n {
					if batch != nil {
						sizes[i], addr = messages[i].N, messages[i].Addr
						if counter != nil && counter.ReadCounter != nil {
							counter.ReadCounter.Add(int64(sizes[i]))
						}
					}
					if sizes[i] > 3 && !b.preserveHeader {
						bufs[i][1] = 0
						bufs[i][2] = 0
						bufs[i][3] = 0
					}
					eps[i] = &conn.StdNetEndpoint{AddrPort: addr.(*net.UDPAddr).AddrPort()}
				}
				return n, nil
			}
		},
	}, uint16(c.LocalAddr().(*net.UDPAddr).Port), nil
}

func (b *bind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.PacketConn != nil {
		close(b.closeCh)
		_ = b.PacketConn.Close()
		b.PacketConn, b.batch, b.counter = nil, nil, nil
	}
	return nil
}

func (b *bind) SetMark(mark uint32) error {
	return nil
}

func (b *bind) Send(bufs [][]byte, ep conn.Endpoint) (err error) {
	b.mu.Lock()
	c, batch, counter := b.PacketConn, b.batch, b.counter
	b.mu.Unlock()

	if c == nil {
		return syscall.EAFNOSUPPORT
	}

	addr := net.UDPAddrFromAddrPort(ep.(*conn.StdNetEndpoint).AddrPort)
	for i := range bufs {
		if len(bufs[i]) > 3 && len(b.reserved) == 3 {
			bufs[i][1] = b.reserved[0]
			bufs[i][2] = b.reserved[1]
			bufs[i][3] = b.reserved[2]
		}
	}
	if batch != nil {
		return b.sendBatch(batch, counter, bufs, addr)
	}
	for i := range bufs {
		_, err = c.WriteTo(bufs[i], addr)
		if err != nil {
			errors.LogErrorInner(context.Background(), err, "bind send err")
			break
		}
	}
	return err
}

func (b *bind) sendBatch(batch *ipv4.PacketConn, counter *PacketCounterConnection, bufs [][]byte, addr *net.UDPAddr) error {
	pooled := batchMessages.Get().(*[]ipv4.Message)
	defer batchMessages.Put(pooled)
	for len(bufs) > 0 {
		messages := (*pooled)[:min(len(bufs), len(*pooled))]
		for i := range messages {
			messages[i].Buffers[0], messages[i].Addr = bufs[i], addr
		}
		n, err := batch.WriteBatch(messages, 0)
		if err != nil {
			errors.LogErrorInner(context.Background(), err, "bind send err")
			return err
		}
		if counter != nil && counter.WriteCounter != nil {
			for _, buf := range bufs[:n] {
				counter.WriteCounter.Add(int64(len(buf)))
			}
		}
		bufs = bufs[n:]
	}
	return nil
}

func (b *bind) ParseEndpoint(s string) (conn.Endpoint, error) {
	if b.resolveFunc == nil {
		e, err := netip.ParseAddrPort(s)
		if err != nil {
			return nil, err
		}
		return &conn.StdNetEndpoint{
			AddrPort: e,
		}, nil
	}
	host, sport, err := net.SplitHostPort(s)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(sport)
	if err != nil {
		return nil, err
	}
	if port < 0 || port > 65535 {
		return nil, errors.New("invalid port " + sport)
	}
	ip, err := b.resolveFunc(host)
	if err != nil {
		return nil, err
	}
	addr, _ := netip.AddrFromSlice(ip)
	return &conn.StdNetEndpoint{
		AddrPort: netip.AddrPortFrom(addr, uint16(port)),
	}, nil
}

func (b *bind) BatchSize() int {
	if batchSyscalls {
		return conn.IdealBatchSize
	}
	return 1
}
