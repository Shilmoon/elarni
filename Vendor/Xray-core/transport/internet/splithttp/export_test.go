package splithttp

import (
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

// SetSetupTimeout lets tests exercise the establishment bound without waiting the real budget.
func SetSetupTimeout(d time.Duration) (restore func()) {
	previous := setupTimeout
	setupTimeout = d
	return func() { setupTimeout = previous }
}

// SetPathChangeTiming shortens how long a connection may stay silent after a network change, and how long changes coalesce.
func SetPathChangeTiming(bound, window time.Duration) (restore func()) {
	pathChange.Lock()
	defer pathChange.Unlock()
	previousBound, previousWindow := pathCheckBound, pathChangeWindow
	pathCheckBound, pathChangeWindow = bound, window
	return func() {
		pathChange.Lock()
		defer pathChange.Unlock()
		pathCheckBound, pathChangeWindow = previousBound, previousWindow
	}
}

// XmuxConnClosed reports whether XMUX holds a connection for dest and settings that it would retire as closed.
func XmuxConnClosed(dest net.Destination, settings *internet.MemoryStreamConfig) bool {
	globalDialerAccess.Lock()
	defer globalDialerAccess.Unlock()
	for _, client := range globalDialerMap[dialerConf{dest, settings}].xmuxClients {
		if client.XmuxConn.IsClosed() {
			return true
		}
	}
	return false
}
