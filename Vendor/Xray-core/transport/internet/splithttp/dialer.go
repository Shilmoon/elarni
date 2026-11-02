package splithttp

import (
	"context"
	gotls "crypto/tls"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"reflect"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
	"weak"

	"github.com/apernet/quic-go"
	"github.com/apernet/quic-go/http3"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	xctx "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/net/cnc"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/common/signal/done"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/browser_dialer"
	"github.com/xtls/xray-core/transport/internet/hysteria/congestion"
	"github.com/xtls/xray-core/transport/internet/hysteria/congestion/bbr"
	"github.com/xtls/xray-core/transport/internet/reality"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
	"github.com/xtls/xray-core/transport/pipe"
	"golang.org/x/net/http2"
)

type dialerConf struct {
	net.Destination
	*internet.MemoryStreamConfig
}

// xmuxDialer is the XMUX manager of one dialerConf; release closes every
// HTTP/1.1 and HTTP/2 connection its clients dialed.
type xmuxDialer struct {
	*XmuxManager
	release context.CancelFunc
}

var (
	globalDialerMap    map[dialerConf]xmuxDialer
	globalDialerAccess sync.Mutex
)

func getHTTPClient(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (DialerClient, *XmuxClient) {
	realityConfig := reality.ConfigFromStreamSettings(streamSettings)

	if browser_dialer.HasBrowserDialer() && realityConfig == nil {
		return &BrowserDialerClient{transportConfig: streamSettings.ProtocolSettings.(*Config)}, nil
	}

	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()

	if globalDialerMap == nil {
		globalDialerMap = make(map[dialerConf]xmuxDialer)
	}

	key := dialerConf{dest, streamSettings}

	dialer, found := globalDialerMap[key]

	if !found {
		transportConfig := streamSettings.ProtocolSettings.(*Config)
		xmuxConfig := transportConfig.Xmux
		if xmuxConfig == nil {
			xmuxConfig = &XmuxConfig{}
		}

		releaseCtx, release := context.WithCancel(context.Background())
		dialer = xmuxDialer{NewXmuxManager(xmuxConfig, func() XmuxConn {
			return createHTTPClient(releaseCtx, dest, streamSettings)
		}), release}
		globalDialerMap[key] = dialer
	}

	xmuxClient := dialer.holdXmuxClient(ctx)
	return xmuxClient.XmuxConn.(DialerClient), xmuxClient
}

// releaseDialers closes every connection dialed for streamSettings, including
// ones with streams in use, and forgets its XMUX managers.
// shortcut: a dial that races the release re-creates its dialer, which then
// lives until the idle timeout as before; remember released configs if that
// shows up on devices.
func releaseDialers(streamSettings *internet.MemoryStreamConfig) {
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()
	for key, dialer := range globalDialerMap {
		if key.MemoryStreamConfig != streamSettings && key.MemoryStreamConfig != streamSettings.DownloadSettings {
			continue
		}
		delete(globalDialerMap, key)
		dialer.release()
		for _, xmuxClient := range dialer.xmuxClients {
			common.Close(xmuxClient.XmuxConn) // HTTP/3 transports
		}
	}
}

// releasableConn is closed when its dialer is released.
type releasableConn struct {
	net.Conn
	stopRelease func() bool
}

func (c *releasableConn) Close() error {
	c.stopRelease()
	return c.Conn.Close()
}

func decideHTTPVersion(tlsConfig *tls.Config, realityConfig *reality.Config) string {
	if realityConfig != nil {
		return "2"
	}
	if tlsConfig == nil {
		return "1.1"
	}
	if len(tlsConfig.NextProtocol) != 1 {
		return "2"
	}
	if tlsConfig.NextProtocol[0] == "http/1.1" {
		return "1.1"
	}
	if tlsConfig.NextProtocol[0] == "h3" {
		return "3"
	}
	return "2"
}

func createHTTPClient(releaseCtx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) DialerClient {
	tlsConfig := tls.ConfigFromStreamSettings(streamSettings)
	realityConfig := reality.ConfigFromStreamSettings(streamSettings)

	httpVersion := decideHTTPVersion(tlsConfig, realityConfig)
	if httpVersion == "3" {
		dest.Network = net.Network_UDP // better to keep this line
	}

	var gotlsConfig *gotls.Config

	if tlsConfig != nil {
		gotlsConfig = tlsConfig.GetTLSConfig(tls.WithDestination(dest))
	}

	transportConfig := streamSettings.ProtocolSettings.(*Config)
	diagnosticID := flightrecorder.NextID()
	if flightrecorder.Enabled() {
		security := int64(0)
		if tlsConfig != nil {
			security = 1
		}
		if realityConfig != nil {
			security = 2
		}
		version := map[string]int64{"1.1": 1, "2": 2, "3": 3}[httpVersion]
		values := map[string]int64{"http_version": version, "security": security, "setup_timeout_ms": setupTimeout.Milliseconds()}
		if x := transportConfig.Xmux; x != nil {
			values["h_keepalive_seconds"] = int64(x.HKeepAlivePeriod)
			values["max_connections_from"] = int64(x.GetNormalizedMaxConnections().From)
			values["max_connections_to"] = int64(x.GetNormalizedMaxConnections().To)
			values["max_concurrency_from"] = int64(x.GetNormalizedMaxConcurrency().From)
			values["max_concurrency_to"] = int64(x.GetNormalizedMaxConcurrency().To)
			values["request_limit_from"] = int64(x.GetNormalizedHMaxRequestTimes().From)
			values["request_limit_to"] = int64(x.GetNormalizedHMaxRequestTimes().To)
			values["reuse_seconds_from"] = int64(x.GetNormalizedHMaxReusableSecs().From)
			values["reuse_seconds_to"] = int64(x.GetNormalizedHMaxReusableSecs().To)
		}
		flightrecorder.Record(flightrecorder.Event{Name: "xhttp_client_created", Connection: diagnosticID, Values: values})
	}

	dialContext := func(ctxInner context.Context) (net.Conn, error) {
		ctxInner, cancel := context.WithTimeout(ctxInner, setupTimeout)
		defer cancel()
		finished, admitted := probe.Begin(ctxInner)
		if !admitted {
			return nil, context.Canceled
		}
		defer finished()
		probe.Emit(ctxInner, "proxy_socket_start", nil, 0)
		var conn net.Conn
		var err error
		if streamSettings.FinalMask != nil {
			conn, err = streamSettings.FinalMask.DialTCP(ctxInner, dest)
		} else {
			conn, err = internet.DialSystem(ctxInner, dest, streamSettings.SocketSettings)
		}
		probe.Emit(ctxInner, "proxy_socket_done", err, 0)
		if err != nil {
			return nil, err
		}
		released := &releasableConn{Conn: conn}
		// sync.Pool drops idle HTTP/1.1 upload sockets, which their finalizers then
		// close; the release hook must not keep them reachable.
		weakReleased := weak.Make(released)
		released.stopRelease = context.AfterFunc(releaseCtx, func() {
			if released := weakReleased.Value(); released != nil {
				released.Conn.Close()
			}
		})
		runtime.AddCleanup(released, func(stop func() bool) { stop() }, released.stopRelease)
		conn = released
		if flightrecorder.Enabled() {
			conn = flightrecorder.TrackConn(conn, diagnosticID, uint32(xctx.IDFromContext(ctxInner)), "xhttp_socket")
		}
		probe.OwnConnection(ctxInner, conn)
		rawConn := conn
		deadline, _ := ctxInner.Deadline()
		if err := rawConn.SetDeadline(deadline); err != nil {
			rawConn.Close()
			return nil, err
		}
		canceled := make(chan struct{})
		stopCancel := context.AfterFunc(ctxInner, func() { rawConn.Close(); close(canceled) })
		stopCancellation := sync.OnceFunc(func() {
			if !stopCancel() {
				<-canceled
			}
		})
		succeeded := false
		defer func() {
			stopCancellation()
			if !succeeded {
				rawConn.Close()
			}
		}()

		if realityConfig != nil {
			probe.Emit(ctxInner, "reality_start", nil, 0)
			secured, err := reality.UClient(conn, realityConfig, ctxInner, dest)
			probe.Emit(ctxInner, "reality_done", err, 0)
			if err != nil {
				return nil, err
			}
			conn = secured
		} else if gotlsConfig != nil {
			probe.Emit(ctxInner, "tls_start", nil, 0)
			if fingerprint := tls.GetFingerprint(tlsConfig.Fingerprint); fingerprint != nil {
				conn = tls.UClient(conn, gotlsConfig, fingerprint)
				if err := conn.(*tls.UConn).HandshakeContext(ctxInner); err != nil {
					probe.Emit(ctxInner, "tls_done", err, 0)
					return nil, err
				}
			} else {
				conn = tls.Client(conn, gotlsConfig)
				if err := conn.(*tls.Conn).HandshakeContext(ctxInner); err != nil {
					probe.Emit(ctxInner, "tls_done", err, 0)
					return nil, err
				}
			}
			probe.Emit(ctxInner, "tls_done", nil, 0)
		}
		stopCancellation()
		if err := ctxInner.Err(); err != nil {
			return nil, err
		}
		if err := rawConn.SetDeadline(time.Time{}); err != nil {
			return nil, err
		}
		succeeded = true
		return conn, nil
	}

	var keepAlivePeriod time.Duration
	if streamSettings.ProtocolSettings.(*Config).Xmux != nil {
		keepAlivePeriod = time.Duration(streamSettings.ProtocolSettings.(*Config).Xmux.HKeepAlivePeriod) * time.Second
	}

	var transport http.RoundTripper
	var pre *preconnect

	if httpVersion == "3" {
		quicParams := streamSettings.QuicParams
		if quicParams == nil {
			quicParams = &internet.QuicParams{
				BbrProfile: string(bbr.ProfileStandard),
			}
		}

		quicConfig := &quic.Config{
			InitialStreamReceiveWindow:     quicParams.InitStreamReceiveWindow,
			MaxStreamReceiveWindow:         quicParams.MaxStreamReceiveWindow,
			InitialConnectionReceiveWindow: quicParams.InitConnReceiveWindow,
			MaxConnectionReceiveWindow:     quicParams.MaxConnReceiveWindow,
			MaxIdleTimeout:                 time.Duration(quicParams.MaxIdleTimeout) * time.Second,
			KeepAlivePeriod:                time.Duration(quicParams.KeepAlivePeriod) * time.Second,
			MaxIncomingStreams:             quicParams.MaxIncomingStreams,
			DisablePathMTUDiscovery:        quicParams.DisablePathMtuDiscovery || (runtime.GOOS != "linux" && runtime.GOOS != "android" && runtime.GOOS != "windows" && runtime.GOOS != "darwin"),
			ChromeParrot:                   !quicParams.DisableChromeParrot,
		}
		if quicParams.MaxIdleTimeout == 0 {
			quicConfig.MaxIdleTimeout = net.ConnIdleTimeout
		}
		if quicParams.KeepAlivePeriod == 0 {
			if keepAlivePeriod == 0 {
				quicConfig.KeepAlivePeriod = net.QuicgoH3KeepAlivePeriod
			} else if keepAlivePeriod > 0 {
				quicConfig.KeepAlivePeriod = keepAlivePeriod
			}
		}
		if quicParams.MaxIncomingStreams == 0 {
			// these two are defaults of quic-go/http3. the default of quic-go (no
			// http3) is different, so it is hardcoded here for clarity.
			// https://github.com/quic-go/quic-go/blob/b8ea5c798155950fb5bbfdd06cad1939c9355878/http3/client.go#L36-L39
			quicConfig.MaxIncomingStreams = -1
		}

		transport = &http3.Transport{
			QUICConfig:      quicConfig,
			TLSClientConfig: gotlsConfig,
			Dial: func(ctx context.Context, addr string, tlsCfg *gotls.Config, cfg *quic.Config) (*quic.Conn, error) {
				var pktConn net.PacketConn
				var udpAddr net.Addr
				if streamSettings.FinalMask != nil {
					conn, err := streamSettings.FinalMask.DialUDP(ctx, dest)
					if err != nil {
						return nil, errors.New("failed to dial to dest").Base(err)
					}
					pktConn = conn.(*net.PacketConnWrapper).PacketConn
					udpAddr = conn.RemoteAddr()
				} else {
					conn, err := internet.DialSystem(ctx, dest, streamSettings.SocketSettings)
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

				if !quicParams.DisableChromeParrot {
					tr.ConnectionIDGenerator = quic.ZeroLengthConnectionIDGenerator{}
					tlsCfg.GetCertificate = nil
				}

				conn, err := tr.DialEarly(ctx, udpAddr, tlsCfg, cfg)
				if err != nil {
					return nil, err
				}
				context.AfterFunc(conn.Context(), func() { tr.Close(); pktConn.Close() })

				switch quicParams.Congestion {
				case "reno":
				case "", "bbr":
					congestion.UseBBR(conn, bbr.Profile(quicParams.BbrProfile))
				case "force-brutal":
					congestion.UseBrutal(conn, quicParams.BrutalUp, quicParams.BrutalDisableLossCompensation)
				default:
					panic(quicParams.Congestion)
				}

				return conn, nil
			},
		}
	} else if httpVersion == "2" {
		if keepAlivePeriod == 0 {
			keepAlivePeriod = net.ChromeH2KeepAlivePeriod
		}
		if keepAlivePeriod < 0 {
			keepAlivePeriod = 0
		}
		pre = &preconnect{dial: func(ctxInner context.Context) (net.Conn, error) {
			return hedgedDial(ctxInner, dialContext)
		}}
		transport = h2Transport(pre.transportDial, keepAlivePeriod)
	} else {
		httpDialContext := func(ctxInner context.Context, network string, addr string) (net.Conn, error) {
			return dialContext(ctxInner)
		}

		transport = &http.Transport{
			DialTLSContext:  httpDialContext,
			DialContext:     httpDialContext,
			IdleConnTimeout: net.ConnIdleTimeout,
			// chunked transfer download with KeepAlives is buggy with
			// http.Client and our custom dial context.
			DisableKeepAlives: true,
		}
	}

	client := &DefaultDialerClient{
		diagnosticID:    diagnosticID,
		transportConfig: transportConfig,
		client: &http.Client{
			Transport: transport,
			// A redirect leads away from the XHTTP server; its status fails the request.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		httpVersion:    httpVersion,
		dialUploadConn: dialContext,
		preconnect:     pre,
	}

	return client
}

// Packet-up keeps posting on a connection past its XMUX request limit while the
// next one does its handshake, by at most this many requests across sessions.
// The default limit ends at 900, so this stays under nginx's keepalive_requests of 1000.
const xmuxOvershoot = 64

// Xray's server drops a connection that sends no request within 4 s
// (ReadHeaderTimeout), so an early connection nobody takes is closed before that.
const preconnectTTL = 2 * time.Second

// preconnect dials an HTTP/2 client's first connection ahead of its first
// request, so a session can move its uploads to the client once the handshake
// is done. The transport's first dial takes that connection over.
// h2Transport is XHTTP's HTTP/2 client over dial's (already secured) connections.
func h2Transport(dial func(context.Context) (net.Conn, error), keepAlivePeriod time.Duration) *http2.Transport {
	// Go's 4 MiB default per stream stayed full for each download the app stopped reading.
	// 2 MiB still carries 130 Mbit/s per stream at 120 ms, like the WireGuard tunnel's cap.
	transport, err := http2.ConfigureTransports(&http.Transport{HTTP2: &http.HTTP2Config{MaxReceiveBufferPerStream: 2 << 20}})
	common.Must(err)
	transport.DialTLSContext = func(ctxInner context.Context, network string, addr string, cfg *gotls.Config) (net.Conn, error) {
		conn, err := dial(ctxInner)
		if err != nil {
			return nil, err
		}
		return &maxFrameClamp{Conn: conn}, nil
	}
	transport.IdleConnTimeout = net.ConnIdleTimeout
	transport.ReadIdleTimeout = keepAlivePeriod
	return transport
}

// maxFrameClamp shows the HTTP/2 client every SETTINGS_MAX_FRAME_SIZE as the spec minimum,
// 16 KiB. Go sizes each upload stream's buffer by it, up to 512 KiB, and Go servers advertise
// 1 MB, so iOS extensions crossed their 50 MB limit (Xray-core #6663). The minimum is always
// valid and frames only get smaller; nothing else in the server's stream changes.
type maxFrameClamp struct {
	net.Conn
	header   [9]byte
	seen     int    // header bytes read so far
	left     int    // payload bytes left in the current frame
	settings bool   // the current frame is a SETTINGS frame (not an ack)
	offset   int    // position in the current 6-byte setting
	id       uint16 // the current setting's identifier
}

func (c *maxFrameClamp) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	for i := 0; i < n; {
		if c.seen < len(c.header) {
			c.header[c.seen] = p[i]
			c.seen++
			i++
			if c.seen == len(c.header) {
				c.left = int(c.header[0])<<16 | int(c.header[1])<<8 | int(c.header[2])
				c.settings = c.header[3] == 0x4 && c.header[4]&0x1 == 0
				c.offset = 0
			}
		} else if !c.settings {
			step := min(c.left, n-i)
			i += step
			c.left -= step
		} else {
			switch c.offset {
			case 0:
				c.id = uint16(p[i]) << 8
			case 1:
				c.id |= uint16(p[i])
			default:
				if c.id == 0x5 { // SETTINGS_MAX_FRAME_SIZE
					p[i] = byte(uint32(16384) >> (8 * (5 - c.offset)))
				}
			}
			c.offset = (c.offset + 1) % 6
			i++
			c.left--
		}
		if c.seen == len(c.header) && c.left == 0 {
			c.seen = 0
		}
	}
	return n, err
}

type preconnect struct {
	dial func(context.Context) (net.Conn, error)
	mu   sync.Mutex
	done *done.Instance // closed when the first dial ends; nil until one starts
	conn net.Conn       // the early connection until a dial takes it
}

// start begins the first dial unless one has begun, and returns its end.
func (p *preconnect) start(ctx context.Context) *done.Instance {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.done == nil {
		ready := done.New()
		p.done = ready
		go func() {
			if conn, err := p.dial(ctx); err == nil {
				p.mu.Lock()
				p.conn = conn
				p.mu.Unlock()
				time.AfterFunc(preconnectTTL, func() {
					if conn := p.take(); conn != nil {
						conn.Close()
					}
				})
			}
			ready.Close()
		}()
	}
	return p.done
}

func (p *preconnect) take() net.Conn {
	p.mu.Lock()
	defer p.mu.Unlock()
	conn := p.conn
	p.conn = nil
	return conn
}

// transportDial takes the early connection, waiting for it while it dials, and
// otherwise dials as before.
func (p *preconnect) transportDial(ctx context.Context) (net.Conn, error) {
	p.mu.Lock()
	first := p.done
	if first == nil {
		// This dial is the first; an early start now waits for it instead.
		first = done.New()
		p.done = first
		p.mu.Unlock()
		defer first.Close()
		return p.dial(ctx)
	}
	p.mu.Unlock()
	select {
	case <-first.Wait():
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if conn := p.take(); conn != nil {
		return conn, nil
	}
	return p.dial(ctx)
}

// connectAhead starts the client's handshake without a request where the
// transport allows it, and returns what closes once its requests need none.
func connectAhead(ctx context.Context, client DialerClient) *done.Instance {
	if c, ok := client.(*DefaultDialerClient); ok && c.preconnect != nil {
		return c.preconnect.start(probe.RequestContext(ctx))
	}
	ready := done.New()
	ready.Close()
	return ready
}

// HTTP/2 makes every request on a client wait for that client's single in-flight
// connection attempt, so one handshake that never gets an answer stalls all of them
// until the request that started it gives up. Race a second attempt once it is late.
const hedgeDelay = time.Second

func hedgedDial(ctx context.Context, dial func(context.Context) (net.Conn, error)) (net.Conn, error) {
	ctx, cancel := context.WithCancel(ctx)
	type attempt struct {
		conn net.Conn
		err  error
	}
	results := make(chan attempt, 2)
	start := func() {
		go func() {
			conn, err := dial(ctx)
			results <- attempt{conn, err}
		}()
	}
	start()
	hedge := time.NewTimer(hedgeDelay)
	defer hedge.Stop()
	pending := 1
	for {
		select {
		case <-hedge.C:
			pending++
			start()
		case r := <-results:
			pending--
			if r.err != nil && pending > 0 {
				continue
			}
			cancel()
			if pending > 0 {
				go func() {
					if loser := <-results; loser.conn != nil {
						loser.conn.Close()
					}
				}()
			}
			return r.conn, r.err
		}
	}
}

func init() {
	common.Must(internet.RegisterTransportDialer(protocolName, Dial))
	common.Must(internet.RegisterTransportReleaser(protocolName, releaseDialers))
}

func Dial(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (stat.Connection, error) {
	tlsConfig := tls.ConfigFromStreamSettings(streamSettings)
	realityConfig := reality.ConfigFromStreamSettings(streamSettings)

	httpVersion := decideHTTPVersion(tlsConfig, realityConfig)
	if httpVersion == "3" {
		dest.Network = net.Network_UDP
	}

	transportConfiguration := streamSettings.ProtocolSettings.(*Config)
	var requestURL url.URL

	if tlsConfig != nil || realityConfig != nil {
		requestURL.Scheme = "https"
	} else {
		requestURL.Scheme = "http"
	}
	requestURL.Host = transportConfiguration.Host
	if requestURL.Host == "" && tlsConfig != nil {
		requestURL.Host = tlsConfig.ServerName
	}
	if requestURL.Host == "" && realityConfig != nil {
		requestURL.Host = realityConfig.ServerName
	}
	if requestURL.Host == "" {
		requestURL.Host = dest.Address.String()
	}
	if browser_dialer.HasBrowserDialer() && realityConfig == nil {
		// For Browser Dialer's optimized IP and non-standard port
		if !(requestURL.Scheme == "http" && dest.Port == 80) && !(requestURL.Scheme == "https" && dest.Port == 443) {
			requestURL.Host += ":" + dest.Port.String()
		}
	}

	requestURL.Path = transportConfiguration.GetNormalizedPath()
	requestURL.RawQuery = transportConfiguration.GetNormalizedQuery()

	httpClient, xmuxClient := getHTTPClient(ctx, dest, streamSettings)
	if flightrecorder.Enabled() {
		if c, ok := httpClient.(*DefaultDialerClient); ok {
			ctx = flightrecorder.WithConnection(ctx, c.diagnosticID)
		}
	}

	mode := transportConfiguration.Mode
	if mode == "" || mode == "auto" {
		mode = "packet-up"
		if realityConfig != nil {
			mode = "stream-one"
			if transportConfiguration.DownloadSettings != nil {
				mode = "stream-up"
			}
		}
	}

	sessionId := ""
	if flightrecorder.Enabled() {
		id := uint64(0)
		if c, ok := httpClient.(*DefaultDialerClient); ok {
			id = c.diagnosticID
		}
		flightrecorder.Record(flightrecorder.Event{Name: "xhttp_dial", Connection: id, Session: uint32(xctx.IDFromContext(ctx)), Values: map[string]int64{"mode": map[string]int64{"packet-up": 1, "stream-up": 2, "stream-one": 3}[mode]}})
	}
	if mode != "stream-one" {
		sessionId = transportConfiguration.GenerateSessionID()
	}

	errors.LogInfo(ctx, fmt.Sprintf("XHTTP is dialing to %s, mode %s, HTTP version %s, host %s", dest, mode, httpVersion, requestURL.Host))

	requestURL2 := requestURL
	httpClient2 := httpClient
	xmuxClient2 := xmuxClient
	if transportConfiguration.DownloadSettings != nil {
		globalDialerAccess.Lock()
		if streamSettings.DownloadSettings == nil {
			streamSettings.DownloadSettings = common.Must2(internet.ToMemoryStreamConfig(transportConfiguration.DownloadSettings))
			if streamSettings.SocketSettings != nil && streamSettings.SocketSettings.Penetrate {
				streamSettings.DownloadSettings.SocketSettings = streamSettings.SocketSettings
			}
		}
		globalDialerAccess.Unlock()
		memory2 := streamSettings.DownloadSettings
		dest2 := *memory2.Destination // just panic
		tlsConfig2 := tls.ConfigFromStreamSettings(memory2)
		realityConfig2 := reality.ConfigFromStreamSettings(memory2)
		httpVersion2 := decideHTTPVersion(tlsConfig2, realityConfig2)
		if httpVersion2 == "3" {
			dest2.Network = net.Network_UDP
		}
		if tlsConfig2 != nil || realityConfig2 != nil {
			requestURL2.Scheme = "https"
		} else {
			requestURL2.Scheme = "http"
		}
		config2 := memory2.ProtocolSettings.(*Config)
		requestURL2.Host = config2.Host
		if requestURL2.Host == "" && tlsConfig2 != nil {
			requestURL2.Host = tlsConfig2.ServerName
		}
		if requestURL2.Host == "" && realityConfig2 != nil {
			requestURL2.Host = realityConfig2.ServerName
		}
		if requestURL2.Host == "" {
			requestURL2.Host = dest2.Address.String()
		}
		if browser_dialer.HasBrowserDialer() && realityConfig2 == nil {
			// For Browser Dialer's optimized IP and non-standard port
			if !(requestURL2.Scheme == "http" && dest2.Port == 80) && !(requestURL2.Scheme == "https" && dest2.Port == 443) {
				requestURL2.Host += ":" + dest2.Port.String()
			}
		}
		requestURL2.Path = config2.GetNormalizedPath()
		requestURL2.RawQuery = config2.GetNormalizedQuery()
		httpClient2, xmuxClient2 = getHTTPClient(ctx, dest2, memory2)
		errors.LogInfo(ctx, fmt.Sprintf("XHTTP is downloading from %s, mode %s, HTTP version %s, host %s", dest2, "stream-down", httpVersion2, requestURL2.Host))
	}

	if xmuxClient != nil {
		xmuxClient.AddRunning()
	}
	if xmuxClient2 != nil && xmuxClient2 != xmuxClient {
		xmuxClient2.AddRunning()
	}
	xmuxClient.release()
	if transportConfiguration.DownloadSettings != nil {
		xmuxClient2.release()
	}
	var closed atomic.Int32

	reader, writer := io.Pipe()
	var uploadResponse io.ReadCloser
	var conn splitConn
	conn = splitConn{
		writer: writer,
		onClose: func() {
			if closed.Add(1) > 1 {
				return
			}
			// Responses first: a stream-one request whose body closed first would fail
			// like a broken connection instead of one its caller ended.
			common.Close(conn.reader)
			reader.Close()
			common.Close(uploadResponse)
			if xmuxClient != nil {
				xmuxClient.DoneRunning()
			}
			if xmuxClient2 != nil && xmuxClient2 != xmuxClient {
				xmuxClient2.DoneRunning()
			}
		},
	}
	dialSucceeded := false
	defer func() {
		if !dialSucceeded {
			conn.onClose()
			common.Close(conn.reader)
			conn.writer.Close()
		}
	}()

	var err error
	if mode == "stream-one" {
		requestURL.Path = transportConfiguration.GetNormalizedPath()
		if xmuxClient != nil {
			xmuxClient.LeftRequests.Add(-1)
		}
		conn.download = xmuxClient
		conn.reader, conn.remoteAddr, conn.localAddr, err = httpClient.OpenStream(ctx, requestURL.String(), sessionId, reader, false)
		if err != nil {
			return nil, err
		}
		dialSucceeded = true
		return diagnosticConnection(ctx, &conn), nil
	} else { // stream-down
		if xmuxClient2 != nil {
			xmuxClient2.LeftRequests.Add(-1)
		}
		conn.download = xmuxClient2
		conn.reader, conn.remoteAddr, conn.localAddr, err = httpClient2.OpenStream(ctx, requestURL2.String(), sessionId, nil, false)
		if err != nil {
			return nil, err
		}
	}
	if mode == "stream-up" {
		if xmuxClient != nil {
			xmuxClient.LeftRequests.Add(-1)
		}
		uploadResponse, _, _, err = httpClient.OpenStream(ctx, requestURL.String(), sessionId, reader, true)
		if err != nil {
			return nil, err
		}
		dialSucceeded = true
		return diagnosticConnection(ctx, &conn), nil
	}

	scMaxEachPostBytes := transportConfiguration.GetNormalizedScMaxEachPostBytes()
	scMinPostsIntervalMs := transportConfiguration.GetNormalizedScMinPostsIntervalMs()

	if scMaxEachPostBytes.From <= 0 {
		panic("`scMaxEachPostBytes` should be bigger than 0")
	}

	maxUploadSize := scMaxEachPostBytes.rand()
	// WithSizeLimit(0) will still allow single bytes to pass, and a lot of
	// code relies on this behavior. Subtract 1 so that together with
	// uploadWriter wrapper, exact size limits can be enforced
	// uploadPipeReader, uploadPipeWriter := pipe.New(pipe.WithSizeLimit(maxUploadSize - 1))
	uploadPipeReader, uploadPipeWriter := pipe.New(pipe.WithSizeLimit(max(0, maxUploadSize-buf.Size)))

	conn.writer = uploadWriter{
		uploadPipeWriter,
		maxUploadSize,
	}

	go func() {
		var seq int64
		var lastWrite time.Time

		dynamicHTTPClient := httpClient
		dynamicXmuxClient := xmuxClient
		var nextHTTPClient DialerClient
		var nextXmuxClient *XmuxClient
		var nextReady *done.Instance
		// The connection posts go to stays open until the session moves on.
		dynamicXmuxClient.hold()
		defer func() {
			dynamicXmuxClient.release()
			if nextReady != nil {
				nextXmuxClient.release()
			}
		}()
		for {
			// by offloading the uploads into a buffered pipe, multiple conn.Write
			// calls get automatically batched together into larger POST requests.
			// without batching, bandwidth is extremely limited.
			remainder, err := uploadPipeReader.ReadMultiBuffer()
			if err != nil {
				break
			}

			doSplit := atomic.Bool{}
			for doSplit.Store(true); doSplit.Load(); {
				var chunk buf.MultiBuffer
				remainder, chunk = buf.SplitSize(remainder, maxUploadSize)
				if chunk.IsEmpty() {
					break
				}

				wroteRequest := done.New()

				ctx := httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
					WroteRequest: func(httptrace.WroteRequestInfo) {
						wroteRequest.Close()
					},
				})

				seqStr := strconv.FormatInt(seq, 10)
				seq += 1

				if scMinPostsIntervalMs.From > 0 {
					time.Sleep(time.Duration(scMinPostsIntervalMs.rand())*time.Millisecond - time.Since(lastWrite))
				}

				lastWrite = time.Now()

				if dynamicXmuxClient != nil {
					left := dynamicXmuxClient.LeftRequests.Add(-1)
					if nextReady == nil && (left <= 0 ||
						(dynamicXmuxClient.UnreusableAt != time.Time{} && lastWrite.After(dynamicXmuxClient.UnreusableAt))) {
						nextHTTPClient, nextXmuxClient = getHTTPClient(ctx, dest, streamSettings)
						nextReady = connectAhead(ctx, nextHTTPClient)
					}
					// Make before break: the server cannot deliver later posts before
					// this one, so keep posting here until the next connection's
					// handshake is done, within a bounded overshoot.
					if nextReady != nil && (nextReady.Done() || left <= -xmuxOvershoot) {
						dynamicXmuxClient.release()
						dynamicHTTPClient, dynamicXmuxClient, nextReady = nextHTTPClient, nextXmuxClient, nil
					}
				}

				dynamicXmuxClient.hold()
				go func(hClient DialerClient, xClient *XmuxClient) {
					defer xClient.release()
					err := hClient.PostPacket(
						ctx,
						requestURL.String(),
						sessionId,
						seqStr,
						chunk,
					)
					wroteRequest.Close()
					if err != nil {
						errors.LogInfoInner(ctx, err, "failed to send upload")
						uploadPipeReader.Interrupt()
						// The lost post leaves the server waiting for it, so a reader would wait for the idle timeout.
						common.Close(conn.reader)
						doSplit.Store(false)
					}
				}(dynamicHTTPClient, dynamicXmuxClient)

				if _, ok := dynamicHTTPClient.(*DefaultDialerClient); ok {
					<-wroteRequest.Wait()
				}
			}
		}
	}()

	dialSucceeded = true
	return diagnosticConnection(ctx, &conn), nil
}

func diagnosticConnection(ctx context.Context, conn net.Conn) stat.Connection {
	if flightrecorder.Enabled() {
		return flightrecorder.TrackConn(conn, flightrecorder.Connection(ctx), uint32(xctx.IDFromContext(ctx)), "xhttp_stream")
	}
	return conn
}

// A wrapper around pipe that ensures the size limit is exactly honored.
//
// The MultiBuffer pipe accepts any single WriteMultiBuffer call even if that
// single MultiBuffer exceeds the size limit, and then starts blocking on the
// next WriteMultiBuffer call. This means that ReadMultiBuffer can return more
// bytes than the size limit. We work around this by splitting a potentially
// too large write up into multiple.
type uploadWriter struct {
	*pipe.Writer
	maxLen int32
}

func (w uploadWriter) Write(b []byte) (int, error) {
	/*
		capacity := int(w.maxLen - w.Len())
		if capacity > 0 && capacity < len(b) {
			b = b[:capacity]
		}
	*/

	buffer := buf.MultiBufferContainer{}
	common.Must2(buffer.Write(b))

	var writed int
	for _, buff := range buffer.MultiBuffer {
		length := int(buff.Len()) // The pipe owns the buffer after WriteMultiBuffer.
		err := w.WriteMultiBuffer(buf.MultiBuffer{buff})
		if err != nil {
			return writed, err
		}
		writed += length
	}
	return writed, nil
}
