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
