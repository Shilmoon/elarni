package splithttp_test

import (
	"context"
	"encoding/binary"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
)

// A UDP flow (a call, a stream, a game) must not queue behind downloads that
// share XHTTP's connections. The line runs at 20 Mbps with a 50 ms RTT, and
// each connection may hold 4 MB at the server, as much as one HTTP/2 stream
// window. Before the fix the flow waited 6 s behind the downloads.
func TestRealtimeFlowSkipsDownloadQueues(t *testing.T) {
	const mbps = 20
	l := newLineWith(mbps*1e6/8, 25*time.Millisecond, 4<<20)
	tr := xhttpTransport(t, l, "xhttp packet-up, default xmux", `{"path":"/x","mode":"packet-up"}`)

	// Three downloads first: every connection the default xmux (maxConnections 3) would give them gets one.
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	defer func() { cancel(); wg.Wait() }()
	var received atomic.Int64
	for range 3 {
		conn, err := tr.dial(ctx)
		if err != nil {
			t.Fatal(err)
		}
		context.AfterFunc(ctx, func() { conn.Close() })
		req := make([]byte, probeRequest)
		req[0] = 'B'
		if _, err := conn.Write(req); err != nil {
			t.Fatal(err)
		}
		wg.Go(func() {
			b := make([]byte, 64<<10)
			for {
				n, err := conn.Read(b)
				received.Add(int64(n))
				if err != nil {
					return
				}
			}
		})
	}
	time.Sleep(time.Second) // the server-side queues fill

	before, began := received.Load(), time.Now()
	delays, sent := realtimeDelays(t, tr, 3*time.Second)
	bulk := float64(received.Load()-before) * 8 / 1e6 / time.Since(began).Seconds()
	p95 := percentile(delays, 0.95)
	t.Logf("realtime p50 %v p95 %v, %d of %d echoed | downloads %.1f Mbps", percentile(delays, 0.5), p95, len(delays), sent, bulk)
	if len(delays) < sent || p95 > 200*time.Millisecond {
		t.Errorf("the UDP flow queued behind the downloads: p95 %v, %d of %d echoes back", p95, len(delays), sent)
	}
	if bulk < 0.9*mbps { // budget: the downloads keep 90% of the line
		t.Errorf("downloads got %.1f Mbps of %d", bulk, mbps)
	}
}

// realtimeDelays sends a timestamped 64-byte message every 10 ms for d on a
// stream dialed for a UDP flow and returns each echo's round trip.
func realtimeDelays(t *testing.T, tr transport, d time.Duration) (delays []time.Duration, sent int) {
	udp := session.ContextWithOutbounds(context.Background(), []*session.Outbound{{Target: net.UDPDestination(net.ParseAddress("192.0.2.1"), 50000)}})
	conn, err := tr.dial(udp)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	req := make([]byte, probeRequest)
	req[0] = 'E'
	if _, err := conn.Write(req); err != nil {
		t.Fatal(err)
	}
	echoes := make(chan time.Duration, 1024)
	go func() {
		defer close(echoes)
		msg := make([]byte, 64)
		for {
			if _, err := io.ReadFull(conn, msg); err != nil {
				return
			}
			echoes <- time.Since(time.Unix(0, int64(binary.BigEndian.Uint64(msg))))
		}
	}()
	for end := time.Now().Add(d); time.Now().Before(end); sent++ {
		msg := make([]byte, 64)
		binary.BigEndian.PutUint64(msg, uint64(time.Now().UnixNano()))
		if _, err := conn.Write(msg); err != nil {
			t.Fatal(err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.AfterFunc(500*time.Millisecond, func() { conn.Close() })
	for delay := range echoes {
		delays = append(delays, delay)
	}
	return delays, sent
}
