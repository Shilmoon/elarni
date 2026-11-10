package tun

import (
	"context"
	"net/netip"
	"strings"
	"syscall"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	c "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
)

// Handler is managing object that tie together tun interface, ip stack and dispatch connections to the routing
type Handler struct {
	ctx             context.Context
	config          *Config
	stack           Stack
	tun             Tun
	policyManager   policy.Manager
	dispatcher      routing.Dispatcher
	tag             string
	sniffingRequest session.SniffingRequest
	uplinkCounter   stats.Counter
	downlinkCounter stats.Counter
	// Elarni: open sessions, read by the embedder, and admission limits of the session table
	tcpSessions                stats.Counter
	udpSessions                stats.Counter
	tcpAdmission, udpAdmission sessionAdmission
	dnsAdmission               sessionAdmission // UDP port 53: lookups get through a full UDP table
	dnsIdle, udpIdle           time.Duration
}

type tunUDPStatsWriter struct {
	writer  buf.Writer
	counter stats.Counter
}

func (w *tunUDPStatsWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	for len(mb) > 0 {
		remaining, packet := buf.SplitFirst(mb)
		packetSize := packet.Len()
		if err := w.writer.WriteMultiBuffer(buf.MultiBuffer{packet}); err != nil {
			buf.ReleaseMulti(remaining)
			return err
		}
		w.counter.Add(int64(packetSize))
		mb = remaining
	}
	return nil
}

// TCPWriter is the writing side of a TCP connection of the stack for the dispatcher. It has no Close: the outbound
// closes its writer when the other side has no more to send, and the system may still be sending
type TCPWriter struct {
	Writer buf.Writer
	// Counter counts what is written, if there is one
	Counter stats.Counter
	// CloseWrite, if set, ends what the app receives (Elarni)
	CloseWrite func() error
}

// Close sends the app a FIN once the response has ended (Elarni): otherwise the app sees it only when the
// whole session closes, after policy uplinkOnly.
func (w *TCPWriter) Close() error {
	if w.CloseWrite == nil {
		return nil
	}
	return w.CloseWrite()
}

func (w *TCPWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	size := mb.Len()
	if err := w.Writer.WriteMultiBuffer(mb); err != nil {
		return err
	}
	if w.Counter != nil {
		w.Counter.Add(int64(size))
	}
	return nil
}

// ConnectionHandler interface with the only method that stack is going to push new connections to
type ConnectionHandler interface {
	HandleConnection(conn net.Conn, destination net.Destination)
}

// Handler implements ConnectionHandler
var _ ConnectionHandler = (*Handler)(nil)

// Handler implements common.Runnable
var _ common.Runnable = (*Handler)(nil)

// Init the Handler instance with necessary parameters
func (t *Handler) Init(ctx context.Context, pm policy.Manager, dispatcher routing.Dispatcher) error {
	// Retrieve tag and sniffing config from context (set by AlwaysOnInboundHandler)
	if inbound := session.InboundFromContext(ctx); inbound != nil {
		t.tag = inbound.Tag
	}
	if content := session.ContentFromContext(ctx); content != nil {
		t.sniffingRequest = content.SniffingRequest
	}

	t.ctx = core.ToBackgroundDetachedContext(ctx)
	t.policyManager = pm
	t.dispatcher = dispatcher
	t.tcpAdmission.limit, t.udpAdmission.limit = tcpLimit.Load(), udpLimit.Load()
	t.tcpAdmission.minIdle, t.udpAdmission.minIdle, t.dnsIdle, t.udpIdle = sessionEvictIdle, sessionEvictIdle, dnsSessionIdle, udpSessionIdle
	t.tcpAdmission.finishedIdle, t.udpAdmission.finishedIdle = tcpFinishedIdle, dnsFinishedIdle
	if t.udpAdmission.limit != 0 {
		t.dnsAdmission.limit = min(dnsSessionLimit, t.udpAdmission.limit)
	}
	t.dnsAdmission.minIdle, t.dnsAdmission.finishedIdle = sessionEvictIdle, dnsFinishedIdle

	if len(t.tag) > 0 && pm.ForSystem().Stats.InboundUplink {
		statsManager := core.MustFromContext(ctx).GetFeature(stats.ManagerType()).(stats.Manager)
		name := "inbound>>>" + t.tag + ">>>traffic>>>uplink"
		c, _ := statsManager.GetOrRegisterCounter(name)
		if c != nil {
			t.uplinkCounter = c
		}
	}
	if len(t.tag) > 0 && pm.ForSystem().Stats.InboundDownlink {
		statsManager := core.MustFromContext(ctx).GetFeature(stats.ManagerType()).(stats.Manager)
		name := "inbound>>>" + t.tag + ">>>traffic>>>downlink"
		c, _ := statsManager.GetOrRegisterCounter(name)
		if c != nil {
			t.downlinkCounter = c
		}
	}
	if len(t.tag) > 0 {
		statsManager := core.MustFromContext(ctx).GetFeature(stats.ManagerType()).(stats.Manager)
		t.tcpSessions, _ = statsManager.GetOrRegisterCounter("inbound>>>" + t.tag + ">>>sessions>>>tcp")
		t.udpSessions, _ = statsManager.GetOrRegisterCounter("inbound>>>" + t.tag + ">>>sessions>>>udp")
	}

	return nil
}

func (t *Handler) Start() error {
	tunName := t.config.Name
	tunInterface, err := NewTun(t.config)
	if err != nil {
		return err
	}

	if t.config.AutoOutboundsInterface != "" {
		tunIndex, err := tunInterface.Index()
		if err != nil {
			_ = tunInterface.Close()
			return err
		}
		if t.config.AutoOutboundsInterface == "auto" {
			t.config.AutoOutboundsInterface = ""
		}
		updater = &InterfaceUpdater{tunIndex: tunIndex, fixedName: t.config.AutoOutboundsInterface}
		updater.Update()
		internet.RegisterDialerController(func(network, address string, c syscall.RawConn) error {
			iface := updater.Get()
			if iface == nil {
				errors.LogInfo(context.Background(), "[tun] falied to set interface > iface == nil")
				return errors.New("iface not found")
			}
			var controlErr, sockErr error
			controlErr = c.Control(func(fd uintptr) {
				addrPort, _ := netip.ParseAddrPort(address)
				// skip loopback
				if addrPort.Addr().IsLoopback() || strings.HasPrefix(strings.ToLower(address), "localhost:") {
					return
				}
				err := setinterface(network, address, fd, iface)
				if err != nil {
					sockErr = errors.New("[tun] falied to set interface").Base(err)
				}
			})
			if sockErr != nil {
				return sockErr
			}
			return controlErr
		})
	}

	errors.LogInfo(t.ctx, tunName, " created")

	tunStackOptions := StackOptions{
		Tun:         tunInterface,
		MTU:         t.config.MTU,
		IdleTimeout: t.policyManager.ForLevel(t.config.UserLevel).Timeouts.ConnectionIdle,
	}
	tunStack, err := NewStack(t.ctx, tunStackOptions, t)
	if err != nil {
		_ = tunInterface.Close()
		return err
	}

	err = tunStack.Start()
	if err != nil {
		_ = tunStack.Close()
		_ = tunInterface.Close()
		return err
	}

	err = tunInterface.Start()
	if err != nil {
		_ = tunStack.Close()
		_ = tunInterface.Close()
		return err
	}

	// Platform-specific system DNS takeover, where the platform implements it.
	// Rather no TUN than one that the system DNS bypasses.
	if c, ok := tunInterface.(interface {
		ConfigureSystemDNS(context.Context, string) error
	}); ok {
		if err := c.ConfigureSystemDNS(t.ctx, t.tag); err != nil {
			_ = tunStack.Close()
			_ = tunInterface.Close()
			return errors.New("unable to set the system DNS (remove autoSystemDnsToGateway to run without)").Base(err)
		}
	}

	t.stack = tunStack
	t.tun = tunInterface

	errors.LogInfo(t.ctx, tunName, " up")
	return nil
}

// HandleConnection pass the connection coming from the ip stack to the routing dispatcher
func (t *Handler) HandleConnection(conn net.Conn, destination net.Destination) {
	admission := &t.tcpAdmission
	if destination.Network == net.Network_UDP {
		admission = &t.udpAdmission
		if destination.Port == 53 {
			admission = &t.dnsAdmission
		}
	}
	var clock *activity
	var admitted *admittedSession
	switch stream := conn.(type) {
	case *udpConn:
		clock = &stream.activity
	case *tcpConn:
		if stream.admitted != nil {
			// admitted before its handshake (Elarni)
			conn, clock = trackWith(stream.tracked, stream)
			admitted = stream.admitted
			break
		}
		conn, clock = trackConn(conn)
	default:
		conn, clock = trackConn(conn)
	}
	clock.touch()
	if admitted == nil {
		admitted = admission.acquire(clock, nil)
	}
	t.serve(conn, destination, admitted)
}

// admitTCP admits a connection before its handshake (Elarni): a full table refuses the SYN with a RST
// instead of a connection that takes the app's request and then resets. It returns a nil session then.
func (t *Handler) admitTCP() (*activeConn, *admittedSession) {
	tracked := newActiveConn(nil)
	tracked.touch()
	return tracked, t.tcpAdmission.acquire(&tracked.activity, nil)
}

// serve dispatches a connection admission took; admitted is nil when it refused the connection.
func (t *Handler) serve(conn net.Conn, destination net.Destination, admitted *admittedSession) {
	// when handling is done with any outcome, always signal back to the incoming connection
	// to close, send completion packets back to the network, and cleanup
	defer conn.Close()
	if admitted == nil {
		return
	}
	defer admitted.release()
	ctx, cancel := context.WithCancel(t.ctx)
	defer cancel()
	closeConn := conn.Close
	if !admitted.attach(func() { cancel(); closeConn() }) {
		return // a full table replaced it while its handshake ran
	}
	var stream *tcpConn
	switch tracked := conn.(type) {
	case *activeBufConn:
		stream, _ = tracked.Conn.(*tcpConn)
	case *activeConn:
		stream, _ = tracked.Conn.(*tcpConn)
	}
	if stream != nil {
		// An app that resets its connection cancels the outbound, which reads nothing from it while it
		// dials (Elarni). Not a FIN: the app may still await the reply.
		stream.whenReset(cancel)
	}
	if destination.Network == net.Network_UDP {
		idle := t.udpIdle
		if destination.Port == 53 {
			idle = t.dnsIdle
		}
		if idle > 0 {
			defer admitted.evictWhenIdle(idle)()
		}
	}
	sessionCounter := t.tcpSessions
	if destination.Network == net.Network_UDP {
		sessionCounter = t.udpSessions
	}
	if sessionCounter != nil {
		sessionCounter.Add(1)
		defer sessionCounter.Add(-1)
	}
	ctx = c.ContextWithID(ctx, session.NewID())

	source := net.DestinationFromAddr(conn.RemoteAddr())

	inbound := session.Inbound{
		Name:          "tun",
		Tag:           t.tag,
		CanSpliceCopy: 3,
		Source:        source,
		User: &protocol.MemoryUser{
			Level: t.config.UserLevel,
		},
	}

	ctx = session.ContextWithInbound(ctx, &inbound)
	ctx = session.ContextWithContent(ctx, &session.Content{
		SniffingRequest: t.sniffingRequest,
	})
	ctx = session.SubContextFromMuxInbound(ctx)

	ctx = log.ContextWithAccessMessage(ctx, &log.AccessMessage{
		From:   inbound.Source,
		To:     destination,
		Status: log.AccessAccepted,
		Reason: "",
	})
	errors.LogInfo(ctx, "processing from ", source, " to ", destination)
	// Elarni: Android names a socket's owner only while it exists; routing asks after sniffing.
	if source.Address.Family().IsIP() && destination.Address.Family().IsIP() {
		net.PrefetchSocketOwner(destination.Network.SystemString(), source.Address.IP().String(), uint16(source.Port), destination.Address.IP().String(), uint16(destination.Port))
	}

	// both kinds of connection are buf.Reader and buf.Writer, what they carry is counted on the way
	reader := &buf.TimeoutWrapperReader{Reader: buf.NewReader(conn), Counter: t.uplinkCounter}
	writer := buf.NewWriter(conn)
	if destination.Network != net.Network_UDP {
		tcpWriter := &TCPWriter{Writer: writer, Counter: t.downlinkCounter}
		if stream != nil {
			tcpWriter.CloseWrite = stream.CloseWrite
		}
		writer = tcpWriter
	} else if t.downlinkCounter != nil {
		writer = &tunUDPStatsWriter{writer: writer, counter: t.downlinkCounter}
	}

	link := &transport.Link{
		Reader: reader,
		Writer: writer,
	}
	if err := t.dispatcher.DispatchLink(ctx, destination, link); err != nil {
		errors.LogError(ctx, errors.New("connection closed").Base(err))
	}
}

// Close implements common.Closable.
func (t *Handler) Close() error {
	return errors.Combine(common.CloseIfExists(t.stack), common.CloseIfExists(t.tun))
}

// Network implements proxy.Inbound
// and exists only to comply to proxy interface, declaring it doesn't listen on any network,
// making the process not open any port for this inbound (input will be network interface)
func (t *Handler) Network() []net.Network {
	return []net.Network{}
}

// Process implements proxy.Inbound
// and exists only to comply to proxy interface, which should never get any inputs due to no listening ports
func (t *Handler) Process(ctx context.Context, network net.Network, conn stat.Connection, dispatcher routing.Dispatcher) error {
	return nil
}

func init() {
	common.Must(common.RegisterConfig((*Config)(nil), func(ctx context.Context, config interface{}) (interface{}, error) {
		t := &Handler{config: config.(*Config)}
		err := core.RequireFeatures(ctx, func(pm policy.Manager, dispatcher routing.Dispatcher) error {
			return t.Init(ctx, pm, dispatcher)
		})
		return t, err
	}))
}
