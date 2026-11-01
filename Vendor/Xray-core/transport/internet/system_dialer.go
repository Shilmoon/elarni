package internet

import (
	"context"
	goerrors "errors"
	"runtime"
	"sync"
	"syscall"
	"time"

	ctxid "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
)

var (
	Controllers           []func(network, address string, c syscall.RawConn) error
	ControllersLock       sync.Mutex
	effectiveSystemDialer SystemDialer = &DefaultSystemDialer{}
)

// RequiredSocketController is an embedding hook set before starting the core.
// Unlike advisory controllers, its errors abort dialing. UDP receives the peer
// address, allowing a VPN runtime to bind the correct physical interface.
var RequiredSocketController func(network, address string, c syscall.RawConn) error

var socketPathListeners struct {
	sync.Mutex
	next int
	all  map[int]func()
}

// OnSocketPathChange runs f each time the embedder reports through
// SocketPathChanged that RequiredSocketController would now bind sockets to
// another interface. Long-lived sockets reopen there; the result unregisters f.
func OnSocketPathChange(f func()) (remove func()) {
	socketPathListeners.Lock()
	defer socketPathListeners.Unlock()
	if socketPathListeners.all == nil {
		socketPathListeners.all = map[int]func(){}
	}
	id := socketPathListeners.next
	socketPathListeners.next++
	socketPathListeners.all[id] = f
	return func() {
		socketPathListeners.Lock()
		delete(socketPathListeners.all, id)
		socketPathListeners.Unlock()
	}
}

// SocketPathChanged runs the functions registered with OnSocketPathChange.
func SocketPathChanged() {
	socketPathListeners.Lock()
	listeners := make([]func(), 0, len(socketPathListeners.all))
	for _, f := range socketPathListeners.all {
		listeners = append(listeners, f)
	}
	socketPathListeners.Unlock()
	for _, f := range listeners {
		f()
	}
}

type SystemDialer interface {
	Dial(ctx context.Context, source net.Address, destination net.Destination, sockopt *SocketConfig) (net.Conn, error)
	DestIpAddress() net.IP
}

type DefaultSystemDialer struct {
	dns dns.Client
	obm outbound.Manager
}

func resolveSrcAddr(network net.Network, src net.Address) net.Addr {
	if src == nil || src == net.AnyIP {
		return nil
	}

	if network == net.Network_TCP {
		return &net.TCPAddr{
			IP:   src.IP(),
			Port: 0,
		}
	}

	return &net.UDPAddr{
		IP:   src.IP(),
		Port: 0,
	}
}

func (d *DefaultSystemDialer) Dial(ctx context.Context, src net.Address, dest net.Destination, sockopt *SocketConfig) (_ net.Conn, dialErr error) {
	if flightrecorder.Enabled() {
		started := time.Now()
		defer func() {
			var native syscall.Errno
			goerrors.As(dialErr, &native)
			flightrecorder.Record(flightrecorder.Event{Name: "socket_dial", Code: probe.Code(dialErr), Session: uint32(ctxid.IDFromContext(ctx)), Values: map[string]int64{"network": int64(dest.Network), "elapsed_ms": time.Since(started).Milliseconds(), "native_error": int64(native)}})
		}()
	}
	errors.LogDebug(ctx, "dialing to "+dest.String())

	if dest.Network == net.Network_UDP {
		destAddr, err := net.ResolveUDPAddr("udp", dest.NetAddr())
		if err != nil {
			return nil, err
		}
		srcAddr := resolveSrcAddr(net.Network_UDP, src)
		if srcAddr == nil {
			// some OS don't support mapped IPv4 dual stack
			// and need to select 0.0.0.0 or [::] manually based on the destination
			wildcard := net.AnyIP.IP()
			if destAddr.IP.To4() == nil {
				wildcard = net.AnyIPv6.IP()
			}
			srcAddr = &net.UDPAddr{
				IP:   wildcard,
				Port: 0,
			}
		}
		var lc net.ListenConfig
		if sockopt != nil || len(Controllers) > 0 || RequiredSocketController != nil {
			lc.Control = func(network, _ string, c syscall.RawConn) error {
				// ListenPacket supplies a local address; dialer controllers need the destination.
				for _, ctl := range Controllers {
					if err := ctl(network, destAddr.String(), c); err != nil {
						return errors.New("failed to apply external controller").Base(err)
					}
				}
				if sockopt != nil {
					var sockErr, controlErr error
					controlErr = c.Control(func(fd uintptr) {
						if sockErr = applyOutboundSocketOptions(network, destAddr.String(), fd, sockopt); sockErr != nil {
							errors.LogInfoInner(ctx, sockErr, "failed to apply socket options")
						}
					})
					if _, ok := sockErr.(*BindError); ok {
						return sockErr
					}
					if controlErr != nil {
						return controlErr
					}
				}
				if RequiredSocketController != nil {
					return RequiredSocketController(network, destAddr.String(), c)
				}
				return nil
			}
		}
		packetConn, err := lc.ListenPacket(ctx, srcAddr.Network(), srcAddr.String())
		var bindErr *BindError
		if err != nil && runtime.GOOS == "windows" && goerrors.As(err, &bindErr) {
			// Keep dual-stack UDP when possible. If the interface cannot bind both
			// families, retry a socket that cannot send on the unbound family.
			network := "udp6"
			if destAddr.IP.To4() != nil {
				network = "udp4"
			}
			packetConn, err = lc.ListenPacket(ctx, network, srcAddr.String())
		}
		packetConn, err = ensureUDPSendCapacity(packetConn, err)
		if err != nil {
			return nil, err
		}
		return &net.PacketConnWrapper{
			PacketConn: packetConn,
			Dest:       destAddr,
		}, nil
	}
	// Chrome defaults
	keepAliveConfig := net.KeepAliveConfig{
		Enable:   true,
		Idle:     45 * time.Second,
		Interval: 45 * time.Second,
		Count:    -1,
	}
	keepAlive := time.Duration(0)
	if sockopt != nil {
		if sockopt.TcpKeepAliveIdle*sockopt.TcpKeepAliveInterval < 0 {
			return nil, errors.New("invalid TcpKeepAliveIdle or TcpKeepAliveInterval value: ", sockopt.TcpKeepAliveIdle, " ", sockopt.TcpKeepAliveInterval)
		}
		if sockopt.TcpKeepAliveIdle < 0 || sockopt.TcpKeepAliveInterval < 0 {
			keepAlive = -1
			keepAliveConfig.Enable = false
		}
		if sockopt.TcpKeepAliveIdle > 0 {
			keepAliveConfig.Idle = time.Duration(sockopt.TcpKeepAliveIdle) * time.Second
		}
		if sockopt.TcpKeepAliveInterval > 0 {
			keepAliveConfig.Interval = time.Duration(sockopt.TcpKeepAliveInterval) * time.Second
		}
	}
	dialer := &net.Dialer{
		Timeout:         time.Second * 16,
		LocalAddr:       resolveSrcAddr(dest.Network, src),
		KeepAlive:       keepAlive,
		KeepAliveConfig: keepAliveConfig,
	}

	if sockopt != nil || len(Controllers) > 0 || RequiredSocketController != nil {
		if sockopt != nil && sockopt.TcpMptcp {
			dialer.SetMultipathTCP(true)
		}
		dialer.Control = func(network, address string, c syscall.RawConn) error {
			for _, ctl := range Controllers {
				if err := ctl(network, address, c); err != nil {
					return errors.New("failed to apply external controller").Base(err)
				}
			}
			if sockopt != nil {
				var sockErr, controlErr error
				controlErr = c.Control(func(fd uintptr) {
					if sockErr = applyOutboundSocketOptions(network, address, fd, sockopt); sockErr != nil {
						errors.LogInfoInner(ctx, sockErr, "failed to apply socket options")
					}
				})
				if _, ok := sockErr.(*BindError); ok {
					return sockErr
				}
				if controlErr != nil {
					return controlErr
				}
			}
			if RequiredSocketController != nil {
				return RequiredSocketController(network, address, c)
			}
			return nil
		}
	}

	return dialer.DialContext(ctx, dest.Network.SystemString(), dest.NetAddr())
}

func (d *DefaultSystemDialer) DestIpAddress() net.IP {
	return nil
}

type SystemDialerAdapter interface {
	Dial(network string, address string) (net.Conn, error)
}

type SimpleSystemDialer struct {
	adapter SystemDialerAdapter
}

func WithAdapter(dialer SystemDialerAdapter) SystemDialer {
	return &SimpleSystemDialer{
		adapter: dialer,
	}
}

func (v *SimpleSystemDialer) Dial(ctx context.Context, src net.Address, dest net.Destination, sockopt *SocketConfig) (net.Conn, error) {
	return v.adapter.Dial(dest.Network.SystemString(), dest.NetAddr())
}

func (d *SimpleSystemDialer) DestIpAddress() net.IP {
	return nil
}

// UseAlternativeSystemDialer replaces the current system dialer with a given one.
// Caller must ensure there is no race condition.
//
// xray:api:stable
func UseAlternativeSystemDialer(dialer SystemDialer) {
	if dialer == nil {
		dialer = &DefaultSystemDialer{}
	}
	effectiveSystemDialer = dialer
}

// RegisterDialerController adds a controller to the effective system dialer.
// The controller can be used to operate on file descriptors before they are put into use.
// It receives the network and resolved remote address, as in net.Dialer.Control.
// It only works when effective dialer is the default dialer.
//
// xray:api:beta
func RegisterDialerController(ctl func(network, address string, c syscall.RawConn) error) error {
	if ctl == nil {
		return errors.New("nil listener controller")
	}

	ControllersLock.Lock()
	Controllers = append(Controllers, ctl)
	ControllersLock.Unlock()

	_, ok := effectiveSystemDialer.(*DefaultSystemDialer)
	if !ok {
		return errors.New("RegisterListenerController not supported in custom dialer")
	}

	return nil
}

type FakePacketConn struct {
	net.Conn
}

func (c *FakePacketConn) ReadFrom(p []byte) (n int, addr net.Addr, err error) {
	n, err = c.Read(p)
	return n, &net.UDPAddr{IP: c.Conn.RemoteAddr().(*net.TCPAddr).IP, Port: c.Conn.RemoteAddr().(*net.TCPAddr).Port}, err
}

func (c *FakePacketConn) WriteTo(p []byte, _ net.Addr) (n int, err error) {
	return c.Write(p)
}

func (c *FakePacketConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: []byte{0, 0, 0, 0}}
}
