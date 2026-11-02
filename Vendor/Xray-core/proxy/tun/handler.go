package tun

import (
	"context"
	"net/netip"
	"strings"
	"syscall"
	"time"

	"github.com/xtls/xray-core/app/dispatcher"
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
	ctx                        context.Context
	config                     *Config
	stack                      Stack
	tun                        Tun
	policyManager              policy.Manager
	dispatcher                 routing.Dispatcher
	tag                        string
	sniffingRequest            session.SniffingRequest
	uplinkCounter              stats.Counter
	downlinkCounter            stats.Counter
	tcpSessions                stats.Counter
	udpSessions                stats.Counter
	tcpAdmission, udpAdmission sessionAdmission
	dnsIdle                    time.Duration
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
	t.tcpAdmission.minIdle, t.udpAdmission.minIdle, t.dnsIdle = sessionEvictIdle, sessionEvictIdle, dnsSessionIdle

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
				return nil
			}
			return c.Control(func(fd uintptr) {
				addrPort, _ := netip.ParseAddrPort(address)
				// skip loopback
				if addrPort.Addr().IsLoopback() || strings.HasPrefix(strings.ToLower(address), "localhost:") {
					return
				}
				err := setinterface(network, address, fd, iface)
				if err != nil {
					errors.LogInfoInner(context.Background(), err, "[tun] falied to set interface")
				}
			})
		})
	}

	errors.LogInfo(t.ctx, tunName, " created")

	tunStackOptions := StackOptions{
		Tun:         tunInterface,
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
		tunStack.Wait()
		return err
	}

	err = tunInterface.Start()
	if err != nil {
		_ = tunStack.Close()
		_ = tunInterface.Close()
		tunStack.Wait()
		return err
	}

	t.stack = tunStack
	t.tun = tunInterface

	errors.LogInfo(t.ctx, tunName, " up")
	return nil
}

// HandleConnection pass the connection coming from the ip stack to the routing dispatcher
func (t *Handler) HandleConnection(conn net.Conn, destination net.Destination) {
	// when handling is done with any outcome, always signal back to the incoming connection
	// to close, send completion packets back to the network, and cleanup
	defer conn.Close()
	var ready func() bool
	if stream, ok := conn.(*tcpConn); ok {
		ready = stream.readable
	}
	ctx, cancel := context.WithCancel(t.ctx)
	defer cancel()
	admission := &t.tcpAdmission
	if destination.Network == net.Network_UDP {
		admission = &t.udpAdmission
	}
	var clock *activity
	if udp, ok := conn.(*udpConn); ok {
		clock = &udp.activity
	} else {
		tracked := &activeConn{Conn: conn}
		conn, clock = tracked, &tracked.activity
	}
	clock.touch()
	closeConn := conn.Close
	admitted := admission.acquire(clock, func() { cancel(); closeConn() })
	if admitted == nil {
		return
	}
	defer admitted.release()
	if destination.Network == net.Network_UDP && destination.Port == 53 && t.dnsIdle > 0 {
		go admitted.evictWhenIdle(ctx.Done(), t.dnsIdle)
	}
	var sessionCounter stats.Counter
	switch destination.Network {
	case net.Network_TCP:
		sessionCounter = t.tcpSessions
	case net.Network_UDP:
		sessionCounter = t.udpSessions
	}
	if sessionCounter != nil {
		sessionCounter.Add(1)
		defer sessionCounter.Add(-1)
	}

	ctx = c.ContextWithID(ctx, session.NewID())

	// if the connection is already closed, conn.RemoteAddr() will be nil
	// due to gvisor weird behavior
	remote := conn.RemoteAddr()
	if remote == nil {
		errors.LogInfo(t.ctx, "dropped quickly closed connection")
		return
	}
	source := net.DestinationFromAddr(remote)
	if destination.Network != net.Network_UDP && (t.uplinkCounter != nil || t.downlinkCounter != nil) {
		conn = &stat.CounterConnection{
			Connection:   conn,
			ReadCounter:  t.uplinkCounter,
			WriteCounter: t.downlinkCounter,
		}
	}

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

	link := &transport.Link{
		Reader: &buf.TimeoutWrapperReader{Reader: buf.NewReader(conn)},
		Writer: buf.NewWriter(conn),
	}
	if ready != nil {
		link.Reader = &buf.TimeoutWrapperReader{Reader: &drainReader{Reader: conn, ready: ready}}
		link.Writer = newTCPWriter(conn)
	}
	if destination.Network == net.Network_UDP {
		// Count datagrams without hiding udpConn's per-packet destinations behind
		// a byte-stream CounterConnection, which pins a reused socket to its first peer.
		link.Reader.(*buf.TimeoutWrapperReader).Counter = t.uplinkCounter
		if t.downlinkCounter != nil {
			link.Writer = &dispatcher.SizeStatWriter{Writer: link.Writer, Counter: t.downlinkCounter}
		}
	}
	if err := t.dispatcher.DispatchLink(ctx, destination, link); err != nil {
		errors.LogError(ctx, errors.New("connection closed").Base(err))
	}
}

// Close implements common.Closable.
func (t *Handler) Close() error {
	err := errors.Combine(common.CloseIfExists(t.stack), common.CloseIfExists(t.tun))
	if t.stack != nil {
		t.stack.Wait()
	}
	return err
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
