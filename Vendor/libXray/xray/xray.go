package xray

import (
	"bytes"
	"errors"
	"fmt"
	"runtime/debug"
	"runtime/metrics"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/libxray/memory"
	"github.com/xtls/libxray/share"
	"github.com/xtls/xray-core/common/cmdarg"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/core"
	featurestats "github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	coreServerMu sync.Mutex
	coreServer   *core.Instance
	memoryLimit  atomic.Int64
)

var ErrAlreadyRunning = errors.New("xray is already running")

type RuntimeMetrics struct {
	HeapAllocBytes    uint64 `json:"heapAllocBytes"`
	HeapSysBytes      uint64 `json:"heapSysBytes"`
	MemoryLimitBytes  int64  `json:"memoryLimitBytes"`
	UplinkBytes       int64  `json:"uplinkBytes"`
	DownlinkBytes     int64  `json:"downlinkBytes"`
	ActiveTCPSessions int64  `json:"activeTcpSessions"`
	ActiveUDPSessions int64  `json:"activeUdpSessions"`
}

func SetMemoryLimit(bytes int64) int64 {
	previous := debug.SetMemoryLimit(bytes)
	memoryLimit.Store(bytes)
	return previous
}

func GetRuntimeMetrics() (RuntimeMetrics, error) {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == nil {
		return RuntimeMetrics{}, errors.New("xray is not running")
	}
	// runtime/metrics, unlike ReadMemStats, does not stop the world; the desktop relays call this every second.
	heap := []metrics.Sample{{Name: "/memory/classes/heap/objects:bytes"}, {Name: "/memory/classes/heap/unused:bytes"},
		{Name: "/memory/classes/heap/free:bytes"}, {Name: "/memory/classes/heap/released:bytes"}}
	metrics.Read(heap)
	result := RuntimeMetrics{MemoryLimitBytes: memoryLimit.Load()}
	for i, sample := range heap {
		if sample.Value.Kind() != metrics.KindUint64 {
			continue
		}
		if i == 0 {
			result.HeapAllocBytes = sample.Value.Uint64() // MemStats.HeapAlloc
		}
		result.HeapSysBytes += sample.Value.Uint64() // MemStats.HeapSys = objects + unused + free + released
	}
	manager, ok := coreServer.GetFeature(featurestats.ManagerType()).(featurestats.Manager)
	if !ok {
		return result, nil
	}
	value := func(name string) int64 {
		if counter := manager.GetCounter(name); counter != nil {
			return counter.Value()
		}
		return 0
	}
	for _, tag := range []string{"elarni-tun", "elarni-socks", "elarni-http"} {
		result.UplinkBytes += value("inbound>>>" + tag + ">>>traffic>>>uplink")
		result.DownlinkBytes += value("inbound>>>" + tag + ">>>traffic>>>downlink")
	}
	result.ActiveTCPSessions = value("inbound>>>elarni-tun>>>sessions>>>tcp")
	result.ActiveUDPSessions = value("inbound>>>elarni-tun>>>sessions>>>udp")
	if flightrecorder.Enabled() {
		flightrecorder.Record(flightrecorder.Event{Name: "core_metrics", Values: map[string]int64{"uplink_bytes": result.UplinkBytes, "downlink_bytes": result.DownlinkBytes, "tcp_sessions": result.ActiveTCPSessions, "udp_sessions": result.ActiveUDPSessions, "memory_limit": result.MemoryLimitBytes}})
	}
	return result, nil
}

func StartXray(configPath string) (*core.Instance, error) {
	file := cmdarg.Arg{configPath}
	config, err := core.LoadConfig("json", file)
	if err != nil {
		return nil, err
	}

	server, err := core.New(config)
	if err != nil {
		return nil, err
	}

	return server, nil
}

func StartXrayFromJSON(configJSON string) (_ *core.Instance, startErr error) {
	if err := share.ValidateClientFileAccess([]byte(configJSON)); err != nil {
		return nil, fmt.Errorf("xray_config_invalid: %w", err)
	}
	if flightrecorder.Enabled() {
		started := time.Now()
		flightrecorder.Record(flightrecorder.Event{Name: "core_start"})
		defer func() {
			flightrecorder.Record(flightrecorder.Event{Name: "core_start_done", Code: probe.Code(startErr), Values: map[string]int64{"elapsed_ms": time.Since(started).Milliseconds()}})
		}()
	}
	config, err := core.LoadConfig("json", bytes.NewReader([]byte(configJSON)))
	if err != nil {
		return nil, fmt.Errorf("xray_config_invalid: %w", err)
	}
	server, err := core.New(config)
	if err != nil {
		return nil, fmt.Errorf("xray_initialization_failed: %w", err)
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		return nil, fmt.Errorf("xray_start_failed: %w", err)
	}
	return server, nil
}

// Run Xray instance with JSON configuration string.
// configJSON means the JSON configuration string.
func RunXrayFromJSON(configJSON string) (err error) {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer != nil {
		return ErrAlreadyRunning
	}

	memory.InitForceFree()
	server, err := StartXrayFromJSON(configJSON)
	if err != nil {
		return
	}
	coreServer = server
	tunnelRules = perAppRules(configJSON)

	debug.FreeOSMemory()
	return nil
}

// Get Xray State
func GetXrayState() bool {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	return coreServer != nil && coreServer.IsRunning()
}

// Stop Xray instance.
func StopXray() error {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer != nil {
		err := coreServer.Close()
		coreServer, tunnelRules = nil, nil
		if err != nil {
			return err
		}
	}
	return nil
}

// Xray's version
func XrayVersion() string {
	return core.Version()
}
