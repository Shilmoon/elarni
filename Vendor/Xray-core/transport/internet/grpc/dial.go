package grpc

import (
	"context"
	"reflect"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common"
	c "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/utils"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/grpc/encoding"
	"github.com/xtls/xray-core/transport/internet/reality"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/status"
)

func Dial(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (stat.Connection, error) {
	errors.LogInfo(ctx, "creating connection to ", dest)

	conn, err := dialgRPC(ctx, dest, streamSettings)
	if err != nil {
		return nil, errors.New("failed to dial gRPC").Base(err)
	}
	return stat.Connection(conn), nil
}

func init() {
	common.Must(internet.RegisterTransportDialer(protocolName, Dial))
	common.Must(internet.RegisterTransportReleaser(protocolName, releaseClients))
}

type dialerConf struct {
	net.Destination
	*internet.MemoryStreamConfig
}

// client is a pooled gRPC connection.
type client struct {
	*grpc.ClientConn
	streams atomic.Int32 // flows on it
	retired atomic.Bool  // set after a socket path change: it closes once its flows end
}

var (
	globalDialerMap    map[dialerConf]*client
	globalDialerAccess sync.Mutex
	watchPathOnce      sync.Once
)

// probeBound is how long a connection kept after a socket path change may take to answer.
var probeBound = 5 * time.Second

func (c *client) release() {
	if c.streams.Add(-1) == 0 && c.retired.Load() {
		c.Close()
	}
}

// answers reports whether the server replies to a request within bound. A client ping
// below the server's 5 min minimum would get the connection closed (too_many_pings),
// so the probe is a health check, which servers answer even when they lack it.
func (c *client) answers(bound time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), bound)
	defer cancel()
	err := c.Invoke(ctx, "/grpc.health.v1.Health/Check", &encoding.Hunk{}, &encoding.Hunk{})
	return status.Code(err) != codes.DeadlineExceeded && c.GetState() == connectivity.Ready
}

// moved retires every pooled connection after the socket path changed: new flows dial on the
// new path, and an old connection closes once its flows end, or at once if it stopped answering.
func moved() {
	globalDialerAccess.Lock()
	retired := make([]*client, 0, len(globalDialerMap))
	for key, c := range globalDialerMap {
		delete(globalDialerMap, key)
		c.retired.Store(true)
		retired = append(retired, c)
	}
	globalDialerAccess.Unlock()
	for _, c := range retired {
		go func() {
			if c.streams.Load() == 0 || !c.answers(probeBound) {
				c.Close()
			}
		}()
	}
}

func watchPath() {
	moves := make(chan struct{}, 1)
	internet.OnSocketPathChange(func() {
		select {
		case moves <- struct{}{}:
		default:
		}
	})
	go coalesce(moves, moved)
}

// coalesce runs pass on each signal; a burst of signals while its checks run gets one more pass.
func coalesce(moves <-chan struct{}, pass func()) {
	for range moves {
		pass()
		time.Sleep(probeBound)
	}
}

// releaseClients closes the gRPC connections dialed for streamSettings,
// including streams in use, and forgets them. Their dialers hold the first
// dial's context, and with it the stopped core.
// shortcut: a dial that races the release re-creates its client, which then
// stays in the map as before; remember released configs if that shows up on
// devices.
func releaseClients(streamSettings *internet.MemoryStreamConfig) {
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()
	for key, conn := range globalDialerMap {
		if key.MemoryStreamConfig == streamSettings {
			delete(globalDialerMap, key)
			conn.Close()
		}
	}
}

func dialgRPC(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (net.Conn, error) {
	grpcSettings := streamSettings.ProtocolSettings.(*Config)

	conn, err := getGrpcClient(ctx, dest, streamSettings)
	if err != nil {
		return nil, errors.New("Cannot dial gRPC").Base(err)
	}
	release := sync.OnceFunc(conn.release)
	client := encoding.NewGRPCServiceClient(conn.ClientConn)
	if grpcSettings.MultiMode {
		errors.LogDebug(ctx, "using gRPC multi mode service name: `"+grpcSettings.getServiceName()+"` stream name: `"+grpcSettings.getTunMultiStreamName()+"`")
		grpcService, err := client.(encoding.GRPCServiceClientX).TunMultiCustomName(ctx, grpcSettings.getServiceName(), grpcSettings.getTunMultiStreamName())
		if err != nil {
			release()
			return nil, errors.New("Cannot dial gRPC").Base(err)
		}
		return encoding.NewMultiHunkConn(grpcService, release, nil), nil
	}

	errors.LogDebug(ctx, "using gRPC tun mode service name: `"+grpcSettings.getServiceName()+"` stream name: `"+grpcSettings.getTunStreamName()+"`")
	grpcService, err := client.(encoding.GRPCServiceClientX).TunCustomName(ctx, grpcSettings.getServiceName(), grpcSettings.getTunStreamName())
	if err != nil {
		release()
		return nil, errors.New("Cannot dial gRPC").Base(err)
	}

	return encoding.NewHunkConn(grpcService, release, nil), nil
}

// getGrpcClient returns the pooled connection for dest, counting the caller's flow on it.
func getGrpcClient(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (*client, error) {
	watchPathOnce.Do(watchPath)
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()

	if globalDialerMap == nil {
		globalDialerMap = make(map[dialerConf]*client)
	}
	tlsConfig := tls.ConfigFromStreamSettings(streamSettings)
	realityConfig := reality.ConfigFromStreamSettings(streamSettings)
	grpcSettings := streamSettings.ProtocolSettings.(*Config)

	if client, found := globalDialerMap[dialerConf{dest, streamSettings}]; found && client.GetState() != connectivity.Shutdown {
		client.streams.Add(1)
		return client, nil
	}

	// The dialer outlives the client: gRPC's stopped idle timer keeps the closed
	// ClientConn for up to 30 min. Keep copies of what dials read, not ctx, which
	// reaches the core.
	sessionID := c.IDFromContext(ctx)
	// dialerProxy and domain lookups need this core's DNS and outbounds, not the
	// process-wide ones that the last started core installed.
	features := internet.SystemDialerFeatures(ctx)
	var outbounds []*session.Outbound
	for _, ob := range session.OutboundsFromContext(ctx) {
		ob := *ob
		outbounds = append(outbounds, &ob)
	}
	dialOptions := []grpc.DialOption{
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff: backoff.Config{
				BaseDelay:  500 * time.Millisecond,
				Multiplier: 1.5,
				Jitter:     0.2,
				MaxDelay:   19 * time.Second,
			},
			MinConnectTimeout: 5 * time.Second,
		}),
		grpc.WithContextDialer(func(gctx context.Context, s string) (net.Conn, error) {
			select {
			case <-gctx.Done():
				return nil, gctx.Err()
			default:
			}

			rawHost, rawPort, err := net.SplitHostPort(s)
			if err != nil {
				return nil, err
			}
			if len(rawPort) == 0 {
				rawPort = "443"
			}
			port, err := net.PortFromString(rawPort)
			if err != nil {
				return nil, err
			}
			address := net.ParseAddress(rawHost)

			gctx = c.ContextWithID(gctx, sessionID)
			gctx = session.ContextWithOutbounds(gctx, outbounds)
			gctx = session.ContextWithTimeoutOnly(gctx, true)
			if features != nil {
				gctx = internet.ContextWithSystemDialerFeatures(gctx, features)
			}

			var c net.Conn
			if streamSettings.FinalMask != nil {
				c, err = streamSettings.FinalMask.DialTCP(gctx, net.TCPDestination(address, port))
			} else {
				c, err = internet.DialSystem(gctx, net.TCPDestination(address, port), streamSettings.SocketSettings)
			}
			if err == nil {
				if tlsConfig != nil {
					config := tlsConfig.GetTLSConfig(tls.WithDestination(dest))
					if fingerprint := tls.GetFingerprint(tlsConfig.Fingerprint); fingerprint != nil {
						return tls.UClient(c, config, fingerprint), nil
					} else { // Fallback to normal gRPC TLS
						return tls.Client(c, config), nil
					}
				}
				if realityConfig != nil {
					return reality.UClient(c, realityConfig, gctx, dest)
				}
			}
			return c, err
		}),
	}

	dialOptions = append(dialOptions, grpc.WithTransportCredentials(insecure.NewCredentials()))

	authority := ""
	if grpcSettings.Authority != "" {
		authority = grpcSettings.Authority
	} else if tlsConfig != nil && tlsConfig.ServerName != "" {
		authority = tlsConfig.ServerName
	} else if realityConfig == nil && dest.Address.Family().IsDomain() {
		authority = dest.Address.Domain()
	}
	dialOptions = append(dialOptions, grpc.WithAuthority(authority))

	if grpcSettings.IdleTimeout > 0 || grpcSettings.HealthCheckTimeout > 0 || grpcSettings.PermitWithoutStream {
		dialOptions = append(dialOptions, grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                time.Second * time.Duration(grpcSettings.IdleTimeout),
			Timeout:             time.Second * time.Duration(grpcSettings.HealthCheckTimeout),
			PermitWithoutStream: grpcSettings.PermitWithoutStream,
		}))
	}

	if grpcSettings.InitialWindowsSize > 0 {
		dialOptions = append(dialOptions, grpc.WithInitialWindowSize(grpcSettings.InitialWindowsSize))
	}

	var grpcDestHost string
	if dest.Address.Family().IsDomain() {
		grpcDestHost = dest.Address.Domain()
	} else {
		grpcDestHost = dest.Address.IP().String()
	}

	conn, err := grpc.NewClient(
		"passthrough:///"+net.JoinHostPort(grpcDestHost, dest.Port.String()),
		dialOptions...,
	)
	if err != nil {
		return nil, err
	}
	userAgent := grpcSettings.UserAgent
	// It's NOT recommended to set the UA of gRPC connections to that of real browsers, as they are fundamentally incapable of initiating real gRPC connections.
	switch userAgent {
	case "chrome", "":
		userAgent = utils.ChromeUA
	case "firefox":
		userAgent = utils.FirefoxUA
	case "edge":
		userAgent = utils.MSEdgeUA
	case "golang":
		userAgent = ""
	}
	setUserAgent(conn, userAgent)
	conn.Connect()
	pooled := &client{ClientConn: conn}
	pooled.streams.Add(1)
	globalDialerMap[dialerConf{dest, streamSettings}] = pooled
	return pooled, nil
}

// setUserAgent overrides the user-agent on a ClientConn to remove the
// "grpc-go/version" suffix that grpc.WithUserAgent unconditionally appends.
func setUserAgent(conn *grpc.ClientConn, ua string) {
	if f := reflect.ValueOf(conn).Elem().FieldByName("dopts").FieldByName("copts").FieldByName("UserAgent"); f.IsValid() {
		*(*string)(f.Addr().UnsafePointer()) = ua
	}
}
