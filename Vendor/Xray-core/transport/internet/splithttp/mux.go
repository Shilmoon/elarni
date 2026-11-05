package splithttp

import (
	"context"
	"crypto/rand"
	"math"
	"math/big"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal/done"
)

type XmuxConn interface {
	IsClosed() bool
}

type XmuxClient struct {
	XmuxConn     XmuxConn
	Running      atomic.Int32
	holds        atomic.Int32 // posts and upload loops; not counted against maxConcurrency
	leftUsage    int32
	LeftRequests atomic.Int32
	UnreusableAt time.Time
	NotUsed      atomic.Bool

	// Download activity. A connection busy with bulk data has a full send queue
	// at the server, and a new stream on it waits for that queue to drain.
	windowStart atomic.Int64
	windowBytes atomic.Int64
	busyUntil   atomic.Int64

	realtime bool // carries UDP flows only
}

// warm reports whether the connection is up, or dialed ahead and waiting, where the
// transport can tell.
func (c *XmuxClient) warm() bool {
	w, ok := c.XmuxConn.(interface{ warm() bool })
	return !ok || w.warm()
}

const (
	busyWindow = time.Second
	busyBytes  = 64 << 10
)

// noteDownload records n downloaded bytes. Races between readers only blur the
// count, which is a heuristic anyway.
func (c *XmuxClient) noteDownload(n int, now time.Time) {
	t := now.UnixNano()
	if t-c.windowStart.Load() >= int64(busyWindow) {
		c.windowStart.Store(t)
		c.windowBytes.Store(0)
	}
	if c.windowBytes.Add(int64(n)) >= busyBytes {
		c.busyUntil.Store(t + int64(busyWindow))
	}
}

func (c *XmuxClient) busy(now time.Time) bool {
	return now.UnixNano() < c.busyUntil.Load()
}

func (c *XmuxClient) AddRunning() {
	c.Running.Add(1)
}

func (c *XmuxClient) DoneRunning() {
	c.Running.Add(-1)
	c.maybeClose()
}

// hold keeps the connection open until release, even once XMUX retires it: over
// HTTP/3 the close ends the requests still in flight on it.
func (c *XmuxClient) hold() {
	if c != nil {
		c.holds.Add(1)
	}
}

func (c *XmuxClient) release() {
	if c != nil {
		c.holds.Add(-1)
		c.maybeClose()
	}
}

// close the XmuxConn if it is not used and has no running requests
func (c *XmuxClient) maybeClose() {
	if c.NotUsed.Load() && c.Running.Load() <= 0 && c.holds.Load() <= 0 {
		common.Close(c.XmuxConn)
	}
}

type XmuxManager struct {
	xmuxConfig  *XmuxConfig
	concurrency int32
	connections int32
	newConnFunc func() XmuxConn
	xmuxClients []*XmuxClient

	// sessionLimit caps the sessions per connection when the transport has a stream
	// limit that waiting requests would run into (HTTP/3); 0 means none.
	sessionLimit int32
	// preDial starts a connection's handshake without a request, or returns nil
	// where the transport cannot.
	preDial func(context.Context, XmuxConn) *done.Instance
}

func NewXmuxManager(xmuxConfig *XmuxConfig, newConnFunc func() XmuxConn) *XmuxManager {
	return &XmuxManager{
		xmuxConfig:  xmuxConfig,
		concurrency: xmuxConfig.GetNormalizedMaxConcurrency().rand(),
		connections: xmuxConfig.GetNormalizedMaxConnections().rand(),
		newConnFunc: newConnFunc,
		xmuxClients: make([]*XmuxClient, 0),
	}
}

func (m *XmuxManager) newXmuxClient(realtime bool) *XmuxClient {
	xmuxClient := &XmuxClient{
		XmuxConn:  m.newConnFunc(),
		leftUsage: -1,
		realtime:  realtime,
	}
	if x := m.xmuxConfig.GetNormalizedCMaxReuseTimes().rand(); x > 0 {
		xmuxClient.leftUsage = x - 1
	}
	xmuxClient.LeftRequests.Store(math.MaxInt32)
	if x := m.xmuxConfig.GetNormalizedHMaxRequestTimes().rand(); x > 0 {
		xmuxClient.LeftRequests.Store(x)
	}
	if x := m.xmuxConfig.GetNormalizedHMaxReusableSecs().rand(); x > 0 {
		xmuxClient.UnreusableAt = time.Now().Add(time.Duration(x) * time.Second)
	}
	m.xmuxClients = append(m.xmuxClients, xmuxClient)
	return xmuxClient
}

// realtimeStream reports whether ctx dials for a UDP flow other than QUIC.
func realtimeStream(ctx context.Context) bool {
	outbounds := session.OutboundsFromContext(ctx)
	if len(outbounds) == 0 {
		return false
	}
	target := outbounds[len(outbounds)-1].Target
	return target.Network == net.Network_UDP && target.Port != 443
}

func (m *XmuxManager) GetXmuxClient(ctx context.Context) *XmuxClient { // when locking
	return m.getXmuxClient(ctx, true)
}

// holdXmuxClient returns a client held until the caller releases it, so another
// dial cannot retire and close it before the caller's session starts running.
func (m *XmuxManager) holdXmuxClient(ctx context.Context) *XmuxClient {
	xmuxClient := m.getXmuxClient(ctx, true)
	xmuxClient.hold()
	return xmuxClient
}

func (m *XmuxManager) GetExistingXmuxClient(ctx context.Context) *XmuxClient {
	return m.getXmuxClient(ctx, false)
}

func (m *XmuxManager) getXmuxClient(ctx context.Context, create bool) *XmuxClient {
	for i := 0; i < len(m.xmuxClients); {
		xmuxClient := m.xmuxClients[i]
		if xmuxClient.XmuxConn.IsClosed() ||
			xmuxClient.leftUsage == 0 ||
			xmuxClient.LeftRequests.Load() <= 0 ||
			(xmuxClient.UnreusableAt != time.Time{} && time.Now().After(xmuxClient.UnreusableAt)) {
			errors.LogDebug(ctx, "XMUX: removing xmuxClient, IsClosed() = ", xmuxClient.XmuxConn.IsClosed(),
				", Running = ", xmuxClient.Running.Load(),
				", leftUsage = ", xmuxClient.leftUsage,
				", LeftRequests = ", xmuxClient.LeftRequests.Load(),
				", UnreusableAt = ", xmuxClient.UnreusableAt)
			xmuxClient.NotUsed.Store(true)
			xmuxClient.maybeClose()
			m.xmuxClients = append(m.xmuxClients[:i], m.xmuxClients[i+1:]...)
		} else {
			i++
		}
	}

	// UDP flows (calls, games, DNS) get connections of their own, one of
	// maxConnections when it is set, because a download sharing their connection
	// keeps up to its 4 MB HTTP/2 window queued at the server in front of them.
	realtime := realtimeStream(ctx)
	pool, connections := m.xmuxClients, m.connections
	if connections != 1 {
		pool = nil
		for _, xmuxClient := range m.xmuxClients {
			if xmuxClient.realtime == realtime {
				pool = append(pool, xmuxClient)
			}
		}
		if connections > 1 {
			if realtime {
				connections = 1
			} else {
				connections--
			}
		}
	}

	if len(pool) == 0 {
		if !create {
			return nil
		}
		errors.LogDebug(ctx, "XMUX: creating xmuxClient because xmuxClients is empty, realtime = ", realtime)
		return m.newXmuxClient(realtime)
	}

	limit := m.concurrency
	if m.sessionLimit > 0 && (limit <= 0 || limit > m.sessionLimit) {
		limit = m.sessionLimit
	}
	xmuxClients := make([]*XmuxClient, 0)
	if limit > 0 {
		for _, xmuxClient := range pool {
			if xmuxClient.Running.Load() < limit {
				xmuxClients = append(xmuxClients, xmuxClient)
			}
		}
	} else {
		xmuxClients = pool
	}

	// Keep new streams off connections that are busy downloading, if any other is
	// free, then off ones that still need a handshake.
	now := time.Now()
	quiet := func(c *XmuxClient) bool { return !c.busy(now) }
	candidates := preferred(preferred(xmuxClients, quiet), (*XmuxClient).warm)

	if create && connections > 0 && len(pool) < int(connections) {
		errors.LogDebug(ctx, "XMUX: creating xmuxClient because maxConnections was not hit, xmuxClients = ", len(pool), ", realtime = ", realtime)
		fresh := m.newXmuxClient(realtime)
		// The flow takes a warm connection, if one is free, while the new one does its handshake.
		if len(candidates) > 0 && quiet(candidates[0]) && candidates[0].warm() && m.preDial != nil && m.preDial(ctx, fresh.XmuxConn) != nil {
			return pick(candidates)
		}
		return fresh
	}

	if len(xmuxClients) == 0 {
		if !create {
			return nil
		}
		errors.LogDebug(ctx, "XMUX: creating xmuxClient because maxConcurrency was hit, xmuxClients = ", len(pool), ", realtime = ", realtime)
		return m.newXmuxClient(realtime)
	}
	return pick(candidates)
}

// preferred returns the clients that pass keep, or all of them if none does.
func preferred(clients []*XmuxClient, keep func(*XmuxClient) bool) []*XmuxClient {
	var kept []*XmuxClient
	for _, c := range clients {
		if keep(c) {
			kept = append(kept, c)
		}
	}
	if len(kept) == 0 {
		return clients
	}
	return kept
}

func pick(xmuxClients []*XmuxClient) *XmuxClient {
	i, _ := rand.Int(rand.Reader, big.NewInt(int64(len(xmuxClients))))
	xmuxClient := xmuxClients[i.Int64()]
	if xmuxClient.leftUsage > 0 {
		xmuxClient.leftUsage -= 1
	}
	return xmuxClient
}

// retire takes every connection out of use for new sessions; the ones carrying
// none close now.
func (m *XmuxManager) retire() {
	for _, xmuxClient := range m.xmuxClients {
		xmuxClient.NotUsed.Store(true)
		xmuxClient.maybeClose()
	}
	m.xmuxClients = nil
}
