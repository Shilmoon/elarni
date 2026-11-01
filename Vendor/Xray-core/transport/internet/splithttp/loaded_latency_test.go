//go:build xhttploaded

// Loopback reproduction of the xhttp loaded-latency gap. It is a measurement,
// not a pass/fail test, so it only builds with the tag:
//
//	go test -tags xhttploaded -run 'TestLoadedLatency|TestQueryPairs' -v -timeout 20m ./Vendor/Xray-core/transport/internet/splithttp
//
// Client and server talk through an emulated line: 29 Mbps server to client,
// 40 ms RTT, a small shared bottleneck queue, and fair share per TCP
// connection. Each connection can also hold a server-side backlog (the
// server's unsent socket buffer), set with ELARNI_XHTTP_BACKLOG_KB (default
// 256). ELARNI_XHTTP_BULK sets the number of downloads (default 4),
// ELARNI_XHTTP_BULK_GAP_MS spaces their starts, and ELARNI_XHTTP_ONLY picks
// cases by index, such as "0,2".
package splithttp_test

import (
	"cmp"
	"context"
	"fmt"
	"io"
	gonet "net"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/grpc"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

func grpcTransport(t *testing.T, l *line) transport {
	server := &internet.MemoryStreamConfig{
		ProtocolName:     "grpc",
		ProtocolSettings: &grpc.Config{ServiceName: "x"},
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{Certificate: []*tls.Certificate{certificate()}},
	}
	ln, err := grpc.Listen(context.Background(), net.LocalHostIP, freePort(t), server, func(conn stat.Connection) { go serveApp(conn) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	dest := destination(t, l.relay(t, ln.Addr().String()))
	client := &internet.MemoryStreamConfig{
		ProtocolName:     "grpc",
		ProtocolSettings: &grpc.Config{ServiceName: "x"},
		SecurityType:     "tls",
		SecuritySettings: &tls.Config{ServerName: "localhost", AllowInsecure: true},
	}
	return transport{name: "grpc (one shared connection)", dial: func(ctx context.Context) (gonet.Conn, error) {
		return grpc.Dial(ctx, dest, client)
	}}
}

func tcpTransport(t *testing.T, l *line) transport {
	ln, err := gonet.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go serveApp(conn)
		}
	}()
	addr := l.relay(t, ln.Addr().String())
	return transport{name: "tcp, one connection per flow", dial: func(ctx context.Context) (gonet.Conn, error) {
		var d gonet.Dialer
		return d.DialContext(ctx, "tcp", addr)
	}}
}

// probeStream opens a new stream and times two request/reply exchanges on it.
func probeStream(tr transport) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	start := time.Now()
	conn, err := tr.dial(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	req := make([]byte, probeRequest)
	req[0] = 'P'
	for _, size := range probeReplies {
		if _, err := conn.Write(req); err != nil {
			return 0, err
		}
		if _, err := io.ReadFull(conn, make([]byte, size)); err != nil {
			return 0, err
		}
	}
	return time.Since(start), nil
}

// queries times `count` back-to-back 64-byte messages on one open stream until
// every reply is back, as a resolver does for A and AAAA.
func queries(t *testing.T, tr transport, count int, gap time.Duration) time.Duration {
	conn, err := tr.dial(context.Background())
	if err != nil {
		t.Fatalf("%s: dial: %v", tr.name, err)
	}
	defer conn.Close()
	req := make([]byte, probeRequest)
	req[0] = 'E'
	if _, err := conn.Write(req); err != nil {
		t.Fatal(err)
	}
	var times []time.Duration
	for range 12 {
		time.Sleep(200 * time.Millisecond)
		start := time.Now()
		for i := range count {
			if i > 0 {
				time.Sleep(gap)
			}
			if _, err := conn.Write(make([]byte, 64)); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := io.ReadFull(conn, make([]byte, 64*count)); err != nil {
			t.Fatal(err)
		}
		times = append(times, time.Since(start))
	}
	return percentile(times[2:], 0.5)
}

func TestQueryPairs(t *testing.T) {
	cases := []func(*line) transport{
		func(l *line) transport { return tcpTransport(t, l) },
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up", `{"path":"/x","mode":"packet-up"}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up, scMinPostsIntervalMs 1", `{"path":"/x","mode":"packet-up","scMinPostsIntervalMs":1}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp stream-one", `{"path":"/x","mode":"stream-one"}`)
		},
	}
	for _, makeCase := range cases {
		tr := makeCase(newLine(256 << 10))
		t.Logf("%-45s one query %3d ms | two at once %3d ms | two 1 ms apart %3d ms | two 5 ms apart %3d ms", tr.name,
			queries(t, tr, 1, 0).Milliseconds(), queries(t, tr, 2, 0).Milliseconds(),
			queries(t, tr, 2, time.Millisecond).Milliseconds(), queries(t, tr, 2, 5*time.Millisecond).Milliseconds())
	}
}

type result struct {
	idle, loaded []time.Duration
	failed       int
	mbps         []float64
}

func measure(t *testing.T, tr transport) result {
	var r result
	// Warm up: the first streams pay for new TLS connections.
	for range 6 {
		if _, err := probeStream(tr); err != nil {
			t.Fatalf("%s: warm-up probe: %v", tr.name, err)
		}
	}
	for range 10 {
		d, err := probeStream(tr)
		if err != nil {
			t.Fatalf("%s: idle probe: %v", tr.name, err)
		}
		r.idle = append(r.idle, d)
		time.Sleep(100 * time.Millisecond)
	}
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	bulk := 4
	if v := os.Getenv("ELARNI_XHTTP_BULK"); v != "" {
		bulk, _ = strconv.Atoi(v)
	}
	gapMs, _ := strconv.Atoi(os.Getenv("ELARNI_XHTTP_BULK_GAP_MS"))
	counts := make([]atomic.Int64, bulk)
	for i := range counts {
		time.Sleep(time.Duration(gapMs) * time.Millisecond)
		conn, err := tr.dial(ctx)
		if err != nil {
			t.Fatalf("%s: bulk dial: %v", tr.name, err)
		}
		req := make([]byte, probeRequest)
		req[0] = 'B'
		if _, err := conn.Write(req); err != nil {
			t.Fatalf("%s: bulk write: %v", tr.name, err)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer conn.Close()
			context.AfterFunc(ctx, func() { conn.Close() })
			b := make([]byte, 64<<10)
			for {
				n, err := conn.Read(b)
				counts[i].Add(int64(n))
				if err != nil {
					return
				}
			}
		}()
	}
	time.Sleep(3 * time.Second) // let the backlogs fill
	before := make([]int64, len(counts))
	for i := range counts {
		before[i] = counts[i].Load()
	}
	began := time.Now()
	for time.Since(began) < 15*time.Second {
		d, err := probeStream(tr)
		if err != nil {
			r.failed++
		} else {
			r.loaded = append(r.loaded, d)
		}
		time.Sleep(300 * time.Millisecond)
	}
	elapsed := time.Since(began).Seconds()
	for i := range counts {
		r.mbps = append(r.mbps, float64(counts[i].Load()-before[i])*8/1e6/elapsed)
	}
	cancel()
	wg.Wait()
	return r
}

func TestLoadedLatency(t *testing.T) {
	backlogKB := 256
	if v := os.Getenv("ELARNI_XHTTP_BACKLOG_KB"); v != "" {
		backlogKB, _ = strconv.Atoi(v)
	}
	only := os.Getenv("ELARNI_XHTTP_ONLY")
	cases := []func(*line) transport{
		func(l *line) transport { return tcpTransport(t, l) },
		func(l *line) transport { return grpcTransport(t, l) },
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up, default xmux (maxConnections 3)", `{"path":"/x","mode":"packet-up"}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp stream-one, default xmux", `{"path":"/x","mode":"stream-one"}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up, maxConnections 1", `{"path":"/x","mode":"packet-up","xmux":{"maxConnections":1}}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up, maxConcurrency 1", `{"path":"/x","mode":"packet-up","xmux":{"maxConcurrency":1}}`)
		},
		func(l *line) transport {
			return xhttpTransport(t, l, "xhttp packet-up, maxConnections 6", `{"path":"/x","mode":"packet-up","xmux":{"maxConnections":6}}`)
		},
	}
	t.Logf("line: %.0f Mbps down, %v RTT, %d KB shared queue, %d KB backlog per connection, bulk downloads %s, %s ms apart",
		lineRate*8/1e6, 2*oneWay, queueBytes>>10, backlogKB, cmp.Or(os.Getenv("ELARNI_XHTTP_BULK"), "4"),
		cmp.Or(os.Getenv("ELARNI_XHTTP_BULK_GAP_MS"), "0"))
	for i, makeCase := range cases {
		if only != "" && !slices.Contains(strings.Split(only, ","), strconv.Itoa(i)) {
			continue
		}
		l := newLine(backlogKB << 10)
		tr := makeCase(l)
		r := measure(t, tr)
		mbps := ""
		total := 0.0
		for _, m := range r.mbps {
			mbps += fmt.Sprintf(" %.1f", m)
			total += m
		}
		t.Logf("%-50s idle %4d ms | loaded median %4d ms, p95 %4d ms, n=%d failed=%d | per stream Mbps%s (total %.1f)",
			tr.name, percentile(r.idle, 0.5).Milliseconds(), percentile(r.loaded, 0.5).Milliseconds(),
			percentile(r.loaded, 0.95).Milliseconds(), len(r.loaded), r.failed, mbps, total)
	}
}
