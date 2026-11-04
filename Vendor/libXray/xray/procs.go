//go:build (darwin && !ios) || windows

package xray

import (
	"os"
	"runtime"
)

// Two Ps cut CPU per GB on an M4 Pro (14 cores) by about 70% for WireGuard and 55%
// for Hysteria2 and raised their download rates; VLESS was unchanged. Idle Ps spinning
// for each packet's goroutine handoff cost more than the parallelism gained. On a Windows
// VM in VPN mode, two Ps halved CPU per GB and sped up single streams for every protocol.
func init() {
	if os.Getenv("GOMAXPROCS") == "" {
		runtime.GOMAXPROCS(min(runtime.NumCPU(), 2))
	}
}
