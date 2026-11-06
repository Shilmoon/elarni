package hysteria

import (
	"context"
	gotls "crypto/tls"
	"net/http"
	"net/url"
	"reflect"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/apernet/quic-go"
	"github.com/apernet/quic-go/http3"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/net/cnc"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/finalmask"
	"github.com/xtls/xray-core/transport/internet/hysteria/congestion"
	"github.com/xtls/xray-core/transport/internet/hysteria/congestion/bbr"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

type client struct {
	lock         chan struct{}
	instance     *core.Instance
	forced       bool
	dest         net.Destination
	config       *Config
	tlsConfig    *gotls.Config
	socketConfig *internet.SocketConfig
	finalMask    *finalmask.FinalMask
	quicParams   *internet.QuicParams

	current *connection   // where new streams open
	dialing *dialing      // the dial that callers without a connection share
	retired []*connection // from before a socket path change, kept for their streams
	moves   int           // socket path changes so far
}

// connection is one QUIC connection of a client.
type connection struct {
	*quic.Conn
	tr        *quic.Transport
	pktConn   net.PacketConn
	udpSM     *udpSessionManager
	streams   atomic.Int32 // open TCP streams
	idleAfter time.Time    // once retired, when it may close for having nothing open
}

type dialing struct {
	done   chan struct{}
	cancel context.CancelFunc
	moves  int
	conn   *connection
	err    error
}

// dialTimeout bounds a dial with its auth request; the server's reply may never come.
var dialTimeout = 10 * time.Second

// probeBound is how long a connection kept after a socket path change may stay silent.
var probeBound = 5 * time.Second

func (c *connection) active() bool {
	return c.Context().Err() == nil
}

func (c *connection) idle() bool {
	return c.streams.Load() == 0 && (c.udpSM == nil || c.udpSM.sessions() == 0)
}

func (c *connection) close() {
	c.CloseWithError(closeErrCodeOK, "")
	c.tr.Close()
	c.pktConn.Close()
}

// answers reports whether the server acknowledges probes within bound. A reset unidirectional
// stream is ack-eliciting, and HTTP/3 servers ignore it. Packets counted by the first tick may
// predate the path change. Without stream credit to probe, the idle timeout decides as before.
func (c *connection) answers(bound time.Duration) bool {
	var received uint64
	probed := false
	for tick := range 5 {
		if stream, err := c.OpenUniStream(); err == nil {
			stream.CancelWrite(closeErrCodeOK)
			probed = true
		}
		select {
		case <-c.Context().Done():
			return false
		case <-time.After(bound / 5):
		}
		now := c.ConnectionStats().PacketsReceived
		if tick > 0 && now != received {
			return true
		}
		received = now
	}
	return !probed
}

// newQuicConfig is the client's QUIC configuration for quicParams.
func newQuicConfig(quicParams *internet.QuicParams) *quic.Config {
	quicConfig := &quic.Config{
		InitialStreamReceiveWindow:     quicParams.InitStreamReceiveWindow,
		MaxStreamReceiveWindow:         quicParams.MaxStreamReceiveWindow,
		InitialConnectionReceiveWindow: quicParams.InitConnReceiveWindow,
		MaxConnectionReceiveWindow:     quicParams.MaxConnReceiveWindow,
		MaxIdleTimeout:                 time.Duration(quicParams.MaxIdleTimeout) * time.Second,
		KeepAlivePeriod:                time.Duration(quicParams.KeepAlivePeriod) * time.Second,
		DisablePathMTUDiscovery:        quicParams.DisablePathMtuDiscovery || (runtime.GOOS != "linux" && runtime.GOOS != "android" && runtime.GOOS != "windows" && runtime.GOOS != "darwin"),
		ChromeParrot:                   !quicParams.DisableChromeParrot,
		EnableDatagrams:                true,
		MaxDatagramFrameSize:           MaxDatagramFrameSize,
		OmitMaxDatagramFrameSize:       true,
		DisablePathManager:             true,
	}
	if quicParams.InitStreamReceiveWindow == 0 {
		quicConfig.InitialStreamReceiveWindow = 8388608
	}
	if quicParams.MaxStreamReceiveWindow == 0 {
		quicConfig.MaxStreamReceiveWindow = 8388608
	}
	if quicParams.InitConnReceiveWindow == 0 {
		quicConfig.InitialConnectionReceiveWindow = 8388608 * 5 / 2
	}
	if quicParams.MaxConnReceiveWindow == 0 {
		quicConfig.MaxConnectionReceiveWindow = 8388608 * 5 / 2
	}
	if quicParams.MaxIdleTimeout == 0 {
		quicConfig.MaxIdleTimeout = 30 * time.Second
	}
	// Elarni: without pings a quiet half minute ended the connection and every stream on it
	// (apernet's client pings every 10 s too).
	if quicParams.KeepAlivePeriod == 0 {
		quicConfig.KeepAlivePeriod = 10 * time.Second
	}
	return quicConfig
}

// dial opens a QUIC connection and authenticates on it.
func (c *client) dial(ctx context.Context) (*connection, error) {
	quicParams := c.quicParams
	if quicParams == nil {
		quicParams = &internet.QuicParams{
			BbrProfile: string(bbr.ProfileStandard),
		}
	}
	quicConfig := newQuicConfig(quicParams)

	var pktConn net.PacketConn
	var udpAddr net.Addr
	if c.finalMask != nil {
		conn, err := c.finalMask.DialUDP(ctx, c.dest)
		if err != nil {
			return nil, errors.New("failed to dial to dest").Base(err)
		}
		pktConn = conn.(*net.PacketConnWrapper).PacketConn
		udpAddr = conn.RemoteAddr()
	} else {
		conn, err := internet.DialSystem(ctx, c.dest, c.socketConfig)
		if err != nil {
			return nil, errors.New("failed to dial to dest").Base(err)
		}
		switch c := conn.(type) {
		case *net.PacketConnWrapper:
			pktConn = c.PacketConn
			udpAddr = c.RemoteAddr()
		case *cnc.Connection:
			pktConn = &internet.FakePacketConn{Conn: c}
			udpAddr = &net.UDPAddr{IP: []byte{0, 0, 0, 0}}
		default:
			panic(reflect.TypeOf(c))
		}
	}

	tr := &quic.Transport{Conn: pktConn, DisableGSO: quicParams.DisableGSO}

	tlsConfig := c.tlsConfig
	if !quicParams.DisableChromeParrot {
		tr.ConnectionIDGenerator = quic.ZeroLengthConnectionIDGenerator{}
		tlsConfig = tlsConfig.Clone() // a dial from before a path change may still run
		tlsConfig.GetCertificate = nil
	}

	var conn *quic.Conn
	rt := &http3.Transport{
		TLSClientConfig: tlsConfig,
		QUICConfig:      quicConfig,
		Dial: func(ctx context.Context, _ string, tlsCfg *gotls.Config, cfg *quic.Config) (*quic.Conn, error) {
			qc, err := tr.DialEarly(ctx, udpAddr, tlsCfg, cfg)
			if err != nil {
				return nil, err
			}
			conn = qc
			return qc, nil
		},
	}
	req := &http.Request{
		Method: http.MethodPost,
		URL: &url.URL{
			Scheme: "https",
			Host:   URLHost,
			Path:   URLPath,
		},
		Header: http.Header{
			RequestHeaderAuth:   []string{c.config.Auth},
			CommonHeaderCCRX:    []string{strconv.FormatUint(quicParams.BrutalDown, 10)},
			CommonHeaderPadding: []string{AuthRequestPadding.String()},
		},
	}
	resp, err := rt.RoundTrip(req.WithContext(ctx))
	if err != nil {
		_ = rt.Close()
		if conn != nil {
			_ = conn.CloseWithError(closeErrCodeProtocolError, "")
		}
		_ = tr.Close()
		_ = pktConn.Close()
		return nil, err
	}
	_ = resp.Body.Close()

	if resp.StatusCode != StatusAuthOK {
		_ = rt.Close()
		_ = conn.CloseWithError(closeErrCodeProtocolError, "")
		_ = tr.Close()
		_ = pktConn.Close()
		return nil, errors.New("auth failed code ", resp.StatusCode)
	}

	// udp, _ := strconv.ParseBool(resp.Header.Get(ResponseHeaderUDPEnabled))
	down, _ := strconv.ParseUint(resp.Header.Get(CommonHeaderCCRX), 10, 64)
	errors.LogDebug(context.Background(), "ECHAccepted ", conn.ConnectionState().TLS.ECHAccepted)

	switch quicParams.Congestion {
	case "reno":
	case "bbr":
		congestion.UseBBR(conn, bbr.Profile(quicParams.BbrProfile))
	case "", "brutal":
		if quicParams.BrutalUp == 0 || down == 0 {
			congestion.UseBBR(conn, bbr.Profile(quicParams.BbrProfile))
		} else {
			congestion.UseBrutal(conn, min(quicParams.BrutalUp, down), quicParams.BrutalDisableLossCompensation)
		}
	case "force-brutal":
		congestion.UseBrutal(conn, quicParams.BrutalUp, quicParams.BrutalDisableLossCompensation)
	default:
		panic(quicParams.Congestion)
	}

	udpSM := &udpSessionManager{
		conn: conn,
		m:    make(map[uint32]*InterConn),
		next: 1,
	}
	go udpSM.run()

	return &connection{Conn: conn, tr: tr, pktConn: pktConn, udpSM: udpSM}, nil
}

func (c *client) unlock() {
	<-c.lock
}

// connection returns the connection new streams open on. Concurrent callers share one dial,
// which neither caller's cancellation ends.
func (c *client) connection(ctx context.Context) (*connection, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case c.lock <- struct{}{}:
	}
	if c.forced {
		c.unlock()
		return nil, errors.New("client is closed")
	}
	if c.current != nil && !c.current.active() {
		c.current.close()
		c.current = nil
	}
	if conn := c.current; conn != nil {
		c.unlock()
		return conn, nil
	}
	d := c.dialing
	if d == nil || d.moves != c.moves { // one from before a path change keeps only its callers
		dialCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), dialTimeout)
		d = &dialing{done: make(chan struct{}), cancel: cancel, moves: c.moves}
		c.dialing = d
		go c.complete(dialCtx, d)
	}
	c.unlock()
	select {
	case <-d.done:
		return d.conn, d.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (c *client) complete(ctx context.Context, d *dialing) {
	conn, err := c.dial(ctx)
	d.cancel()
	c.lock <- struct{}{}
	switch {
	case err != nil:
	case c.forced:
		conn.close()
		conn, err = nil, errors.New("client is closed")
	case c.moves != d.moves:
		c.retire(conn) // its socket may be on the old path: its callers use it, new streams dial again
	default:
		c.current = conn
	}
	if c.dialing == d {
		c.dialing = nil
	}
	d.conn, d.err = conn, err
	c.unlock()
	close(d.done)
}

func (c *client) tcp(ctx context.Context) (stat.Connection, error) {
	conn, err := c.connection(ctx)
	if err != nil {
		return nil, err
	}

	// Elarni: past the server's stream limit, wait for the credit of a closed stream
	// instead of failing; other dials may proceed meanwhile.
	conn.streams.Add(1)
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		conn.streams.Add(-1)
		return nil, err
	}

	return &interConn{
		stream: stream,
		local:  conn.LocalAddr(),
		remote: conn.RemoteAddr(),

		client:  true,
		lock:    make(chan struct{}, 1),
		release: func() { conn.streams.Add(-1) },
	}, nil
}

func (c *client) udp(ctx context.Context) (stat.Connection, error) {
	conn, err := c.connection(ctx)
	if err != nil {
		return nil, err
	}
	return conn.udpSM.udp()
}

// moved retires the connection new streams open on, after the socket path changed.
func (c *client) moved() {
	c.lock <- struct{}{}
	c.moves++
	if c.current != nil {
		c.retire(c.current)
		c.current = nil
	}
	c.unlock()
}

// retire keeps conn for its open streams, and closes it if the server stops answering.
func (c *client) retire(conn *connection) {
	conn.idleAfter = time.Now().Add(probeBound)
	c.retired = append(c.retired, conn)
	go func() {
		if !conn.answers(probeBound) {
			conn.close()
		}
	}()
}

func (c *client) clean(force bool) {
	c.lock <- struct{}{}
	defer c.unlock()
	if force {
		c.forced = true
		if c.dialing != nil {
			c.dialing.cancel()
		}
	}
	if c.current != nil && (force || !c.current.active()) {
		c.current.close()
		c.current = nil
	}
	now := time.Now()
	kept := c.retired[:0]
	for _, conn := range c.retired {
		if force || !conn.active() || now.After(conn.idleAfter) && conn.idle() {
			conn.close()
		} else {
			kept = append(kept, conn)
		}
	}
	clear(c.retired[len(kept):])
	c.retired = kept
}

type dialerConf struct {
	net.Destination
	*internet.MemoryStreamConfig
}

type clientManager struct {
	sync.RWMutex
	m map[dialerConf]*client
}

func (m *clientManager) clean() {
	ticker := time.NewTicker(idleCleanupInterval)
	for range ticker.C {
		m.RLock()
		entries := make(map[dialerConf]*client, len(m.m))
		for k, c := range m.m {
			entries[k] = c
		}
		m.RUnlock()
		for k, c := range entries {
			force := c.instance != nil && !c.instance.IsRunning()
			c.clean(force)
			if force {
				m.Lock()
				delete(m.m, k)
				m.Unlock()
			}
		}
	}
}

// watchPath retires every client's connection when the socket path changes. A burst of
// signals while the checks run coalesces into one more pass.
func (m *clientManager) watchPath(moves <-chan struct{}) {
	for range moves {
		m.RLock()
		clients := make([]*client, 0, len(m.m))
		for _, c := range m.m {
			clients = append(clients, c)
		}
		m.RUnlock()
		for _, c := range clients {
			c.moved()
		}
		time.Sleep(probeBound)
	}
}

func (m *clientManager) start() {
	moves := make(chan struct{}, 1)
	internet.OnSocketPathChange(func() {
		select {
		case moves <- struct{}{}:
		default:
		}
	})
	go m.clean()
	go m.watchPath(moves)
}

var (
	manager     = &clientManager{m: make(map[dialerConf]*client)}
	initmanager sync.Once
)

// releaseClients closes the QUIC connections dialed for streamSettings,
// including streams in use, and forgets their clients. The cleaner closes a
// stopped core's clients on its next tick only, and an outbound removed from a
// running core keeps them alive with keepalives (XTLS/Xray-core#7100).
// shortcut: a Dial that races the release re-creates its client, which then
// stays in the map as before; remember released configs if that shows up on
// devices.
func releaseClients(streamSettings *internet.MemoryStreamConfig) {
	var released []*client
	manager.Lock()
	for key, c := range manager.m {
		if key.MemoryStreamConfig == streamSettings {
			delete(manager.m, key)
			released = append(released, c)
		}
	}
	manager.Unlock()
	for _, c := range released {
		c.clean(true)
	}
}

func Dial(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (stat.Connection, error) {
	tlsConfig := tls.ConfigFromStreamSettings(streamSettings)
	if tlsConfig == nil {
		return nil, errors.New("tls config is nil")
	}

	datagram := DatagramFromContext(ctx)
	dest.Network = net.Network_UDP

	initmanager.Do(manager.start)

	dialerConfKey := dialerConf{dest, streamSettings}

	manager.RLock()
	c := manager.m[dialerConfKey]
	manager.RUnlock()

	if c == nil {
		manager.Lock()
		c = manager.m[dialerConfKey]
		if c == nil {
			c = &client{
				lock:         make(chan struct{}, 1),
				instance:     core.FromContext(ctx),
				dest:         dest,
				config:       streamSettings.ProtocolSettings.(*Config),
				tlsConfig:    tlsConfig.GetTLSConfig(tls.WithDestination(dest)),
				socketConfig: streamSettings.SocketSettings,
				finalMask:    streamSettings.FinalMask,
				quicParams:   streamSettings.QuicParams,
			}
			manager.m[dialerConfKey] = c
		}
		manager.Unlock()
	}

	if datagram {
		return c.udp(ctx)
	}
	return c.tcp(ctx)
}

func init() {
	common.Must(internet.RegisterTransportDialer(protocolName, Dial))
	common.Must(internet.RegisterTransportReleaser(protocolName, releaseClients))
}
