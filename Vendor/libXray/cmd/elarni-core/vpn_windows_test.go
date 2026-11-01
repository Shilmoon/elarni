//go:build windows

package main

import (
	"bytes"
	"net"
	"strings"
	"testing"

	"github.com/xtls/xray-core/proxy/tun"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// Windows NLA keeps a network profile for every adapter GUID it sees, so a
// session's identity must not change between connects or releases.
func TestTunnelAdapterIdentityIsFixedPerSession(t *testing.T) {
	name := tunnelAdapter(1)
	// The physical route and DNS filters skip adapters with this prefix.
	if !strings.HasPrefix(strings.ToLower(name), "elarni-") {
		t.Fatalf("adapter name %q", name)
	}
	if got := tun.AdapterGUID(name).String(); got != "{B1FC6508-D4D3-2523-4B87-F70E40703D17}" {
		t.Fatalf("adapter GUID changed to %s", got)
	}
	// Another user's helper may still hold its adapter.
	if *tun.AdapterGUID(tunnelAdapter(2)) == *tun.AdapterGUID(name) {
		t.Fatal("two Windows sessions share an adapter GUID")
	}
}

// Another program's interface may hold the name; Wintun then renames one of the
// two, so only the requested GUID identifies the adapter.
func TestTunnelInterfaceResolvesByGUIDNotName(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	for _, existing := range interfaces {
		if existing.Flags&net.FlagLoopback == 0 {
			continue
		}
		luid, err := winipcfg.LUIDFromIndex(uint32(existing.Index))
		if err != nil {
			t.Fatal(err)
		}
		guid, err := luid.GUID()
		if err != nil {
			t.Fatal(err)
		}
		if row, err := tunnelInterface(guid); err != nil || row.InterfaceLUID != luid {
			t.Fatalf("GUID %s did not resolve %q: %v", guid, existing.Name, err)
		}
		if row, err := tunnelInterface(tun.AdapterGUID(existing.Name)); err == nil {
			t.Fatalf("interface %q was adopted by its name as %q", existing.Name, row.Alias())
		}
		return
	}
	t.Skip("no loopback interface to resolve")
}

// The recording switch crosses the strict pipe to the elevated child.
func TestVPNHandshakeCarriesTheRecordingSwitch(t *testing.T) {
	var pipe bytes.Buffer
	if err := writeFrame(&pipe, vpnHandshake{Version: 1, Config: "{}", RecordDiagnostics: true}); err != nil {
		t.Fatal(err)
	}
	command, err := readVPNCommand(&pipe)
	if err != nil || !command.RecordDiagnostics {
		t.Fatalf("handshake lost the switch: %v", err)
	}
}
