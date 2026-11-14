//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
	"google.golang.org/protobuf/proto"
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

// vpnTestChild stands in for the elevated child behind startVPN: it handles each start as
// vpnChild does and reports the geodata bytes that crossed the pipe for it.
type vpnTestChild struct {
	held     heldAssets
	release  chan struct{} // the hold expired
	fail     chan struct{} // the next start fails after its files arrived
	received chan int
}

func startVPNTestChild(t testing.TB) *vpnTestChild {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	// The broker only waits on and names this handle; it lacks the right to terminate.
	process, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, windows.GetCurrentProcessId())
	if err != nil {
		t.Fatal(err)
	}
	child := &vpnTestChild{release: make(chan struct{}, 1), fail: make(chan struct{}, 1), received: make(chan int, 8)}
	replies := make(chan vpnReply, 1)
	vpnBroker.Lock()
	vpnBroker.pipe, vpnBroker.process, vpnBroker.replies, vpnBroker.closed, vpnBroker.assets = write, process, replies, false, ""
	vpnBroker.Unlock()
	reader := filesystem.NewAssetReader
	t.Cleanup(func() {
		vpnBroker.Lock()
		vpnBroker.pipe, vpnBroker.process, vpnBroker.replies, vpnBroker.closed, vpnBroker.assets = nil, 0, nil, false, ""
		vpnBroker.Unlock()
		write.Close()
		read.Close()
		windows.CloseHandle(process)
		filesystem.NewAssetReader = reader
	})
	go func() {
		for {
			command, err := readVPNCommand(read)
			if err != nil {
				return
			}
			select {
			case <-child.release:
				child.held = heldAssets{}
			default:
			}
			sent := 0
			for _, data := range command.assets {
				sent += len(data)
			}
			child.received <- sent
			reply := vpnReply{Ready: true, Adapter: "elarni-test"}
			select {
			case <-child.fail:
				reply = vpnReply{Error: "vpn_core_failed"}
			default:
				if command.ReuseAssets && !child.held.holds(command.AssetRevision) {
					reply = vpnReply{Error: errAssetsReleased.Error()}
				} else if child.held.load(command) != nil {
					reply = vpnReply{Error: "vpn_assets_failed"}
				}
			}
			replies <- reply
		}
	}()
	return child
}

// transfers lists the geodata bytes each handshake of the last start carried.
func (child *vpnTestChild) transfers() []int {
	var sent []int
	for {
		select {
		case n := <-child.received:
			sent = append(sent, n)
		default:
			return sent
		}
	}
}

func writeTestRevision(t testing.TB, root, revision string, geoip []byte) {
	if err := os.MkdirAll(filepath.Join(root, revision), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, revision, "geoip.dat"), geoip, 0600); err != nil {
		t.Fatal(err)
	}
}

func testVPNStart(revision string) error {
	payload, _ := json.Marshal(map[string]any{"assetRevision": revision, "configJSON": `{"inbounds":[{"protocol":"tun","settings":{}},{"protocol":"socks","listen":"127.0.0.1","port":10890}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`})
	_, err := startVPN(payload)
	return err
}

func servedGeoIP(t testing.TB) []byte {
	reader, err := filesystem.NewAssetReader("geoip.dat")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(reader)
	return data
}

// A reconnect used to read, send and check both geofiles again. The long-lived child keeps
// the files it verified, so only a new revision, a failed start or an expired hold sends them.
func TestReconnectSendsGeodataOnlyForANewRevision(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("LocalAppData", cache)
	root := filepath.Join(cache, "Elarni", "assets")
	first, second := strings.Repeat("a", 64), strings.Repeat("b", 64)
	geoip := map[string][]byte{}
	for revision, ip := range map[string][]byte{first: {192, 0, 2, 0}, second: {198, 51, 100, 0}} {
		geoip[revision], _ = proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "TEST", Cidr: []*geodata.CIDR{{Ip: ip, Prefix: 24}}}}})
		writeTestRevision(t, root, revision, geoip[revision])
	}
	child := startVPNTestChild(t)
	expect := func(step string, revision string, want ...int) {
		t.Helper()
		if err := testVPNStart(revision); err != nil {
			t.Fatalf("%s: %v", step, err)
		}
		if got := child.transfers(); !slices.Equal(got, want) {
			t.Fatalf("%s: geodata bytes per handshake %v, want %v", step, got, want)
		}
		if !bytes.Equal(servedGeoIP(t), geoip[revision]) {
			t.Fatalf("%s: the core would read another revision's geoip", step)
		}
	}
	expect("first connect", first, len(geoip[first]))
	// Nothing is read from the cache either: the child's verified copy is this revision.
	if err := os.RemoveAll(filepath.Join(root, first)); err != nil {
		t.Fatal(err)
	}
	expect("same revision", first, 0)
	expect("refreshed routing data", second, len(geoip[second]))
	child.release <- struct{}{}
	expect("after the hold", second, 0, len(geoip[second]))
	child.fail <- struct{}{}
	if err := testVPNStart(second); err == nil || !slices.Equal(child.transfers(), []int{0}) {
		t.Fatalf("failed start: %v", err)
	}
	expect("after a failed start", second, len(geoip[second]))
	expect("reconnect", second, 0)
}

// The asset path of a reconnect with full-size geofiles: the same revision against new
// files, which every reconnect sent and checked before.
func BenchmarkVPNReconnectAssets(b *testing.B) {
	cache := b.TempDir()
	b.Setenv("LocalAppData", cache)
	root := filepath.Join(cache, "Elarni", "assets")
	revision := strings.Repeat("c", 64)
	cidrs := make([]*geodata.CIDR, 1<<20)
	domains := make([]*geodata.Domain, 1<<18)
	for i := range cidrs {
		cidrs[i] = &geodata.CIDR{Ip: []byte{10, byte(i >> 16), byte(i >> 8), byte(i)}, Prefix: 32}
	}
	for i := range domains {
		domains[i] = &geodata.Domain{Value: "d" + strings.Repeat("x", 16) + string(rune('a'+i%26)) + ".example", Type: geodata.Domain_Full}
	}
	geoip, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "TEST", Cidr: cidrs}}})
	geosite, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: domains}}})
	writeTestRevision(b, root, revision, geoip)
	if err := os.WriteFile(filepath.Join(root, revision, "geosite.dat"), geosite, 0600); err != nil {
		b.Fatal(err)
	}
	for _, name := range []string{"same revision", "new files"} {
		b.Run(name, func(b *testing.B) {
			child := startVPNTestChild(b)
			if err := testVPNStart(revision); err != nil {
				b.Fatal(err)
			}
			child.transfers()
			sent := 0
			b.ResetTimer()
			for range b.N {
				if name == "new files" {
					vpnBroker.Lock()
					vpnBroker.assets = ""
					vpnBroker.Unlock()
				}
				if err := testVPNStart(revision); err != nil {
					b.Fatal(err)
				}
				for _, n := range child.transfers() {
					sent += n
				}
			}
			b.ReportMetric(float64(sent)/float64(b.N), "geodata-B/op")
		})
	}
}

// The child checks every file it receives; a reuse names only files it holds.
func TestVPNChildReusesOnlyTheRevisionItVerified(t *testing.T) {
	reader := filesystem.NewAssetReader
	defer func() { filesystem.NewAssetReader = reader }()
	first, second := strings.Repeat("a", 64), strings.Repeat("b", 64)
	data, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "TEST", Cidr: []*geodata.CIDR{{Ip: []byte{192, 0, 2, 0}, Prefix: 24}}}}})
	var held heldAssets
	start := func(revision string, reuse bool, files map[string][]byte) vpnCommand {
		return vpnCommand{vpnHandshake: vpnHandshake{AssetRevision: revision, ReuseAssets: reuse}, assets: files}
	}
	if held.load(start(first, false, map[string][]byte{"geoip.dat": []byte("invalid")})) == nil || held.holds(first) {
		t.Fatal("unverified files were kept")
	}
	if held.load(start(first, false, map[string][]byte{"geoip.dat": data})) != nil || !held.holds(first) {
		t.Fatal("verified files were not kept")
	}
	if held.load(start(second, true, nil)) == nil {
		t.Fatal("another revision reused this one's files")
	}
	if held.load(start(second, false, map[string][]byte{"geoip.dat": []byte("invalid")})) == nil || held.holds(first) {
		t.Fatal("a failed load left the previous files to reuse")
	}
	// A reuse that also sends files is refused: every received file is checked.
	var pipe bytes.Buffer
	if err := writeFrame(&pipe, vpnHandshake{Version: 1, AssetRevision: first, ReuseAssets: true, Assets: map[string]int{"geoip.dat": 1}}); err != nil {
		t.Fatal(err)
	}
	pipe.WriteByte(0)
	if _, err := readVPNCommand(&pipe); err == nil {
		t.Fatal("a reuse with files was accepted")
	}
}

// Regression: with Block traffic without VPN, each restart the app made (another server,
// a settings change, failover) lifted the guard with the old tunnel, and traffic left
// outside until the next tunnel had its own.
func TestChildGuardStaysForARestart(t *testing.T) {
	for _, test := range []struct {
		name              string
		code              int
		hold, block, keep bool
	}{
		{"a disconnect", 0, false, true, false},
		{"a restart stop", 0, true, true, true},
		{"a restart stop without the block setting", 0, true, false, false},
		{"a lost tunnel", 1, false, true, true},
		{"a lost tunnel without the block setting", 1, false, false, false},
	} {
		guard := childGuard{installed: true, hold: test.hold}
		guard.ended(test.code, test.block)
		if guard.keep != test.keep || guard.hold {
			t.Errorf("after %s the guard is %+v, want keep %v", test.name, guard, test.keep)
		}
	}
	// A disconnect during a restart lifts what the restart kept; another restart stop does not.
	guard := childGuard{installed: true, hold: true}
	guard.ended(0, true)
	guard.idleStop(true)
	if !guard.keep {
		t.Fatal("a repeated restart stop lifted the guard")
	}
	guard.idleStop(false)
	if guard.keep {
		t.Fatal("a disconnect during a restart kept traffic blocked")
	}
	// The stop that follows a lost tunnel keeps it: only the next tunnel or Repair lifts it.
	guard = childGuard{installed: true}
	guard.ended(1, true)
	guard.idleStop(false)
	if !guard.keep {
		t.Fatal("a stop lifted a lost tunnel's guard")
	}
	// A start that fails after a restart stop is a lost tunnel under the new request's setting.
	guard = childGuard{installed: true, hold: true}
	guard.ended(0, true)
	guard.ended(1, false)
	if guard.keep {
		t.Fatal("a failed start without the block setting kept traffic blocked")
	}
}
