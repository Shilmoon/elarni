package main

import (
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
)

func TestMetricsGateHoldsBackOnlyUnchangedTraffic(t *testing.T) {
	var gate metricsGate
	start := time.Unix(1000, 0)
	idle := xray.RuntimeMetrics{UplinkBytes: 10, DownlinkBytes: 20, HeapAllocBytes: 1 << 20, MemoryLimitBytes: 1 << 30}
	steps := []struct {
		name    string
		metrics xray.RuntimeMetrics
		logs    bool
		after   time.Duration
		want    bool
	}{
		{"first frame", idle, false, 0, true},
		{"unchanged", idle, false, time.Second, false},
		{"heap moved only", xray.RuntimeMetrics{UplinkBytes: 10, DownlinkBytes: 20, HeapAllocBytes: 2 << 20, HeapSysBytes: 9, MemoryLimitBytes: 1 << 30}, false, 2 * time.Second, false},
		{"logs came", idle, true, 3 * time.Second, true},
		{"uplink moved", xray.RuntimeMetrics{UplinkBytes: 11, DownlinkBytes: 20, MemoryLimitBytes: 1 << 30}, false, 4 * time.Second, true},
		{"a session opened", xray.RuntimeMetrics{UplinkBytes: 11, DownlinkBytes: 20, ActiveTCPSessions: 1, MemoryLimitBytes: 1 << 30}, false, 5 * time.Second, true},
		{"unchanged again", xray.RuntimeMetrics{UplinkBytes: 11, DownlinkBytes: 20, ActiveTCPSessions: 1, MemoryLimitBytes: 1 << 30}, false, 14 * time.Second, false},
		{"heartbeat", xray.RuntimeMetrics{UplinkBytes: 11, DownlinkBytes: 20, ActiveTCPSessions: 1, MemoryLimitBytes: 1 << 30}, false, 15 * time.Second, true},
	}
	for _, step := range steps {
		if got := gate.due(step.metrics, step.logs, start.Add(step.after)); got != step.want {
			t.Fatalf("%s: due = %v, want %v", step.name, got, step.want)
		}
	}
}
