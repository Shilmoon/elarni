// Package tuic integrates the TUIC v5 client with Xray's socket and lifecycle owners.
package tuic

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"os"
	"sync"
	"time"

	qtls "github.com/sagernet/sing-quic"
	quic "github.com/sagernet/sing-quic/tuic"
	M "github.com/sagernet/sing/common/metadata"
	ST "github.com/sagernet/sing/common/tls"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal"
	"github.com/xtls/xray-core/common/task"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/proxy"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	xTLS "github.com/xtls/xray-core/transport/internet/tls"
)

type Client struct {
	mu       sync.Mutex
	config   *ClientConfig
	stream   *internet.MemoryStreamConfig
	policy   policy.Manager
	up, down stats.Counter
	client   *quic.Client
	sockets  *socketDialer
	cancel   context.CancelFunc
	closed   bool
}

func NewClient(ctx context.Context, config *ClientConfig) (*Client, error) {
	if config.Address == nil || config.Port == 0 || config.Port > 65535 || len(config.Uuid) != 16 || config.Heartbeat <= 0 {
		return nil, errors.New("invalid TUIC client configuration")
	}
	stream, ok := session.StreamSettingsFromContext(ctx).(*internet.MemoryStreamConfig)
	if !ok || xTLS.ConfigFromStreamSettings(stream) == nil {
		return nil, errors.New("TUIC requires TLS")
	}
	v := core.MustFromContext(ctx)
	c := &Client{config: config, stream: stream, policy: v.GetFeature(policy.ManagerType()).(policy.Manager)}
	if h := session.FullHandlerFromContext(ctx); h != nil && h.Tag() != "" {
		sm := v.GetFeature(stats.ManagerType()).(stats.Manager)
		c.up = sm.GetCounter("outbound>>>" + h.Tag() + ">>>traffic>>>uplink")
		c.down = sm.GetCounter("outbound>>>" + h.Tag() + ">>>traffic>>>downlink")
	}
	return c, nil
}

// initialize keeps shared offers owned by this outbound, never by one stream.
func (c *Client) initialize(ctx context.Context, dialer internet.Dialer) (*quic.Client, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, os.ErrClosed
	}
	if c.client != nil {
		return c.client, nil
	}
	destination := xnet.UDPDestination(c.config.Address.AsAddress(), xnet.Port(c.config.Port))
	owner := &session.Outbound{Target: destination, Name: "tuic"}
	dialer.SetOutboundGateway(ctx, owner)
	// Copy only the physical gateway; the upstream session owns no foreground request.
	ownerCtx := session.ContextWithOutbounds(context.WithoutCancel(ctx), []*session.Outbound{owner})
	ownerCtx, cancel := context.WithCancel(ownerCtx)
	tlsSettings := xTLS.ConfigFromStreamSettings(c.stream)
	tlsConfig := tlsSettings.GetTLSConfig(xTLS.WithDestination(destination))
	if len(tlsSettings.NextProtocol) == 0 {
		tlsConfig.NextProtos = []string{"h3"}
	}
	tlsConfig.MinVersion = tls.VersionTLS13
	var id [16]byte
	copy(id[:], c.config.Uuid)
	sockets := &socketDialer{sockopt: c.stream.SocketSettings, sockets: make(map[*ownedSocket]struct{})}
	client, err := quic.NewClient(quic.ClientOptions{Context: ownerCtx, Dialer: sockets,
		ServerAddress: M.ParseSocksaddr(destination.NetAddr()), TLSConfig: &tlsAdapter{config: tlsConfig, timeout: 10 * time.Second},
		UUID: id, Password: c.config.Password, CongestionControl: c.config.CongestionControl,
		UDPStream: c.config.UdpStream, Heartbeat: time.Duration(c.config.Heartbeat), ZeroRTTHandshake: c.config.ZeroRttHandshake,
		// quic-go starts the connection window at 3 MB, which two stalled downloads filled,
		// so every new stream on the connection waited until they were read.
		QUICOptions: qtls.QUICOptions{ConnectionReceiveWindow: 16 << 20}})
	if err != nil {
		cancel()
		return nil, errors.New("invalid TUIC options")
	}
	c.client, c.cancel, c.sockets = client, cancel, sockets
	return client, nil
}

func (c *Client) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	client, cancel, sockets := c.client, c.cancel, c.sockets
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if client != nil {
		client.CloseWithError(os.ErrClosed)
	}
	if sockets != nil {
		sockets.Close()
	}
	return nil
}

var _ proxy.LargePacketCarrier = (*Client)(nil)

// CarriesLargePackets implements proxy.LargePacketCarrier.
func (c *Client) CarriesLargePackets() {}

func (c *Client) Process(ctx context.Context, link *transport.Link, dialer internet.Dialer) error {
	outbounds := session.OutboundsFromContext(ctx)
	if len(outbounds) == 0 || !outbounds[len(outbounds)-1].Target.IsValid() {
		return errors.New("TUIC target not specified")
	}
	ob := outbounds[len(outbounds)-1]
	ob.Name, ob.CanSpliceCopy = "tuic", 3
	client, err := c.initialize(ctx, dialer)
	if err != nil {
		return err
	}
	target := ob.Target
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	p := c.policy.ForLevel(0)
	timer := signal.CancelAfterInactivity(ctx, cancel, p.Timeouts.ConnectionIdle)
	defer timer.SetTimeout(0)
	var reader buf.Reader
	var writer buf.Writer
	var closer io.Closer
	var handshake func() error
	if target.Network == xnet.Network_TCP {
		conn, err := client.DialConn(ctx, M.ParseSocksaddr(target.NetAddr()))
		if err != nil {
			return err
		}
		// sing-quic sends CONNECT with the first payload; a server that speaks
		// first needs it alone once the client stays silent.
		if lazy, ok := conn.(interface{ NeedHandshake() bool }); ok {
			handshake = func() error {
				if !lazy.NeedHandshake() {
					return nil
				}
				_, err := conn.Write(nil)
				return err
			}
		}
		conn = &stat.CounterConnection{Connection: conn, ReadCounter: c.down, WriteCounter: c.up}
		closer, reader, writer = conn, buf.NewReader(conn), buf.NewWriter(conn)
	} else if target.Network == xnet.Network_UDP {
		conn, err := client.ListenPacket(ctx)
		if err != nil {
			return err
		}
		closer = conn
		reader = &packetReader{conn: conn, counter: c.down}
		writer = &packetWriter{conn: conn, target: target, counter: c.up}
	} else {
		return errors.New("TUIC supports TCP and UDP")
	}
	defer closer.Close()
	stop := context.AfterFunc(ctx, func() { closer.Close(); common.Interrupt(link.Reader); common.Interrupt(link.Writer) })
	defer stop()
	request := func() error {
		defer timer.SetTimeout(p.Timeouts.DownlinkOnly)
		if handshake != nil {
			// A client that half-closed without data still waits for the server to speak.
			if err := buf.CopyOnceTimeout(link.Reader, writer, 100*time.Millisecond); err != nil && err != io.EOF && err != buf.ErrNotTimeoutReader && err != buf.ErrReadTimeout {
				return err
			}
			if err := handshake(); err != nil {
				return err
			}
		}
		return buf.Copy(link.Reader, writer, buf.UpdateActivity(timer))
	}
	response := func() error {
		defer timer.SetTimeout(p.Timeouts.UplinkOnly)
		return buf.Copy(reader, link.Writer, buf.UpdateActivity(timer))
	}
	return task.Run(ctx, request, task.OnSuccess(response, task.Close(link.Writer)))
}

// quicSocketBuffer is the size quic-go asks for on sockets it owns.
const quicSocketBuffer = 7 << 20

// DialSystem applies DNS strategy, UDP chaining and the mandatory platform controller.
// sing-quic accepts this packet-oriented net.Conn directly, preserving datagrams.
type socketDialer struct {
	sockopt *internet.SocketConfig
	mu      sync.Mutex
	closed  bool
	sockets map[*ownedSocket]struct{}
}

func (d *socketDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if network != "udp" {
		return nil, errors.New("TUIC upstream requires UDP")
	}
	done, admitted := probe.Begin(ctx)
	if !admitted {
		return nil, os.ErrClosed
	}
	conn, err := internet.DialSystem(ctx, xnet.UDPDestination(xnet.ParseAddress(destination.AddrString()), xnet.Port(destination.Port)), d.sockopt)
	if err != nil {
		done()
		return nil, err
	}
	if wrapper, ok := conn.(*xnet.PacketConnWrapper); ok {
		if udp, ok := wrapper.PacketConn.(*net.UDPConn); ok {
			// quic-go cannot reach the socket behind this wrapper to enlarge its buffers
			// itself; the defaults (768 KiB on macOS) dropped datagrams during transfers.
			_ = udp.SetReadBuffer(quicSocketBuffer)
			_ = udp.SetWriteBuffer(quicSocketBuffer)
		}
	}
	owned := &ownedSocket{Conn: conn}
	owned.done = func() { done(); d.mu.Lock(); delete(d.sockets, owned); d.mu.Unlock() }
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		owned.Close()
		return nil, os.ErrClosed
	}
	d.sockets[owned] = struct{}{}
	d.mu.Unlock()
	probe.OwnConnection(ctx, owned)
	if ctx.Err() != nil {
		owned.Close()
		return nil, ctx.Err()
	}
	return owned, nil
}

func (d *socketDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("TUIC uses connected upstream datagrams")
}

func (d *socketDialer) Close() {
	d.mu.Lock()
	d.closed = true
	sockets := make([]*ownedSocket, 0, len(d.sockets))
	for socket := range d.sockets {
		sockets = append(sockets, socket)
	}
	d.mu.Unlock()
	for _, socket := range sockets {
		socket.Close()
	}
}

type ownedSocket struct {
	net.Conn
	once sync.Once
	done func()
}

func (c *ownedSocket) Close() error {
	var err error
	c.once.Do(func() { err = c.Conn.Close(); c.done() })
	return err
}

type tlsAdapter struct {
	config  *tls.Config
	timeout time.Duration
}

func (c *tlsAdapter) ServerName() string                    { return c.config.ServerName }
func (c *tlsAdapter) SetServerName(s string)                { c.config.ServerName = s }
func (c *tlsAdapter) NextProtos() []string                  { return c.config.NextProtos }
func (c *tlsAdapter) SetNextProtos(p []string)              { c.config.NextProtos = p }
func (c *tlsAdapter) HandshakeTimeout() time.Duration       { return c.timeout }
func (c *tlsAdapter) SetHandshakeTimeout(t time.Duration)   { c.timeout = t }
func (c *tlsAdapter) STDConfig() (*tls.Config, error)       { return c.config, nil }
func (c *tlsAdapter) Client(conn net.Conn) (ST.Conn, error) { return tls.Client(conn, c.config), nil }
func (c *tlsAdapter) Clone() ST.Config {
	return &tlsAdapter{config: c.config.Clone(), timeout: c.timeout}
}

type packetWriter struct {
	conn    net.PacketConn
	target  xnet.Destination
	counter stats.Counter
}

func (w *packetWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	defer buf.ReleaseMulti(mb)
	for _, b := range mb {
		target := w.target
		if b.UDP != nil {
			target = *b.UDP
		}
		n, err := w.conn.WriteTo(b.Bytes(), M.ParseSocksaddr(target.NetAddr()))
		if w.counter != nil {
			w.counter.Add(int64(n))
		}
		if err != nil {
			return err
		}
	}
	return nil
}

type packetReader struct {
	conn    net.PacketConn
	counter stats.Counter
	scratch []byte
}

func (r *packetReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	if r.scratch == nil {
		r.scratch = make([]byte, 65535)
	}
	n, address, err := r.conn.ReadFrom(r.scratch)
	if err != nil {
		return nil, err
	}
	if r.counter != nil {
		r.counter.Add(int64(n))
	}
	// Queued datagrams keep their buffers; size each to its data, as freedom does.
	b := buf.NewWithSize(int32(n))
	b.Write(r.scratch[:n])
	peer := M.SocksaddrFromNet(address)
	destination := xnet.UDPDestination(xnet.ParseAddress(peer.AddrString()), xnet.Port(peer.Port))
	b.UDP = &destination
	return buf.MultiBuffer{b}, nil
}

func init() {
	common.Must(common.RegisterConfig((*ClientConfig)(nil), func(ctx context.Context, config interface{}) (interface{}, error) {
		return NewClient(ctx, config.(*ClientConfig))
	}))
}
