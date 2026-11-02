//go:build !windows

package wireguard

import "gvisor.dev/gvisor/pkg/tcpip"

// tunnelClock returns the clock for the tunnel's TCP/IP stack; nil keeps gVisor's default,
// which reads Go's nanosecond monotonic clock here.
func tunnelClock() tcpip.Clock {
	return nil
}
