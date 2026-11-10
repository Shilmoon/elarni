//go:build windows || linux

package main

import (
	"net/netip"

	"github.com/xtls/libxray/share"
	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/common/flightrecorder"
)

// moveOpenedConnections resets the listed apps' connections that were open before the tunnel,
// so they reconnect through it; the connections view lists them. The tunnel's own addresses
// are its gateways (share.WindowsTunnelConfig, also on Linux).
func moveOpenedConnections() {
	tunnel := make([]netip.Prefix, 0, 2)
	for _, gateway := range []string{share.TunGateway4, share.TunGateway6} {
		if prefix, err := netip.ParsePrefix(gateway); err == nil {
			tunnel = append(tunnel, prefix.Masked())
		}
	}
	reset, kept := xray.MoveOpenedConnections(tunnel)
	if flightrecorder.Enabled() && reset+kept > 0 {
		flightrecorder.Record(flightrecorder.Event{Name: "opened_connections", Values: map[string]int64{"reset": int64(reset), "kept": int64(kept)}})
	}
}
