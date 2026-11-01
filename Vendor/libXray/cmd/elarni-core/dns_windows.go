//go:build windows

package main

// WFP ABI declarations follow fwpmtypes.h and WireGuard's MIT-licensed Windows
// bindings (Copyright 2019-2026 WireGuard LLC).
import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/xtls/libxray/share"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/probe"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

var siteLocal = netip.MustParsePrefix("fec0::/10")

// Only the helper's system resolver changes. Windows applications still query
// the TUN, and explicit profile DNS servers keep their configured routing.
func readPhysicalDNSServers() ([]string, error) {
	adapters, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagDefault)
	if err != nil {
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "windows_dns_servers", Code: "enumeration_failed"})
		}
		return nil, errors.New("dns_unavailable")
	}
	servers := []string{}
	seen := map[string]bool{}
	for _, adapter := range adapters {
		if adapter.OperStatus != winipcfg.IfOperStatusUp || strings.HasPrefix(strings.ToLower(adapter.FriendlyName()), "elarni-") {
			continue
		}
		for dns := adapter.FirstDNSServerAddress; dns != nil; dns = dns.Next {
			address, ok := netip.AddrFromSlice(dns.Address.IP())
			if !ok {
				continue
			}
			address = address.Unmap()
			// Windows lists deprecated site-local placeholders on interfaces without IPv6
			// DNS; Go's own resolver skips fec0::/10 too.
			if address.IsUnspecified() || address.IsMulticast() || siteLocal.Contains(address) || address.String() == share.TunDNS4 || address.String() == share.TunDNS6 {
				continue
			}
			if address.Is6() && address.IsLinkLocalUnicast() {
				address = address.WithZone(strconv.Itoa(int(adapter.IPv6IfIndex)))
			}
			server := net.JoinHostPort(address.String(), "53")
			if !seen[server] {
				servers = append(servers, server)
				seen[server] = true
			}
		}
	}
	if flightrecorder.Enabled() {
		code := "ok"
		if len(servers) == 0 {
			code = "physical_dns_unavailable"
		}
		flightrecorder.Record(flightrecorder.Event{Name: "windows_dns_servers", Code: code, Values: map[string]int64{"servers": int64(len(servers))}})
	}
	return servers, nil
}

func physicalResolver(servers []string, control func(string, string, syscall.RawConn) error) *net.Resolver {
	var next atomic.Uint64
	dialer := &net.Dialer{Timeout: 5 * time.Second, Control: control}
	return &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (_ net.Conn, dialErr error) {
		if flightrecorder.Enabled() {
			started := time.Now()
			defer func() {
				flightrecorder.Record(flightrecorder.Event{Name: "windows_dns_dial", Code: probe.Code(dialErr), Values: map[string]int64{"elapsed_ms": time.Since(started).Milliseconds(), "servers": int64(len(servers))}})
			}()
		}
		if len(servers) == 0 {
			return nil, errors.New("physical_dns_unavailable")
		}
		for _, server := range servers {
			if server == address {
				return dialer.DialContext(ctx, network, server)
			}
		}
		// An OS-selected synthetic server must never feed the lookup into the TUN.
		return dialer.DialContext(ctx, network, servers[(next.Add(1)-1)%uint64(len(servers))])
	}}
}

type wfpBlob struct {
	Size uint32
	Data *byte
}
type wfpValue struct {
	Type  uint32
	Value uintptr
}
type wfpDisplay struct{ Name, Description *uint16 }
type wfpCondition struct {
	Field windows.GUID
	Match uint32
	Value wfpValue
}
type wfpAction struct {
	Type   uint32
	Filter windows.GUID
}
type wfpSession struct {
	Key                       windows.GUID
	Display                   wfpDisplay
	Flags, Timeout, ProcessID uint32
	SID                       *windows.SID
	Username                  *uint16
	KernelMode                int32
}
type wfpSublayer struct {
	Key      windows.GUID
	Display  wfpDisplay
	Flags    uint32
	Provider *windows.GUID
	Data     wfpBlob
	Weight   uint16
}
type wfpFilter struct {
	Key             windows.GUID
	Display         wfpDisplay
	Flags           uint32
	Provider        *windows.GUID
	Data            wfpBlob
	Layer, Sublayer windows.GUID
	Weight          wfpValue
	Count           uint32
	Conditions      *wfpCondition
	Action          wfpAction
	_               [4]byte // Native union containing uint64/GUID has 8-byte alignment.
	Context         windows.GUID
	Reserved        *windows.GUID
	ID              uint64
	EffectiveWeight wfpValue
}

var wfpDLL = windows.NewLazySystemDLL("fwpuclnt.dll")
var wfpOpen = wfpDLL.NewProc("FwpmEngineOpen0")
var wfpClose = wfpDLL.NewProc("FwpmEngineClose0")
var wfpBegin = wfpDLL.NewProc("FwpmTransactionBegin0")
var wfpCommit = wfpDLL.NewProc("FwpmTransactionCommit0")
var wfpAbort = wfpDLL.NewProc("FwpmTransactionAbort0")
var wfpAddSublayer = wfpDLL.NewProc("FwpmSubLayerAdd0")
var wfpAddFilter = wfpDLL.NewProc("FwpmFilterAdd0")
var wfpAppID = wfpDLL.NewProc("FwpmGetAppIdFromFileName0")
var wfpFree = wfpDLL.NewProc("FwpmFreeMemory0")
var wfpDeleteFilter = wfpDLL.NewProc("FwpmFilterDeleteByKey0")
var wfpDeleteSublayer = wfpDLL.NewProc("FwpmSubLayerDeleteByKey0")

func wfpGUID(text string) windows.GUID {
	guid, err := windows.GUIDFromString("{" + text + "}")
	if err != nil {
		panic(err)
	}
	return guid
}

// Fixed keys let any later helper find a guard whose helper crashed.
var guardSublayer = wfpGUID("871f497c-30a8-4ff1-9f6e-d7a01719bd34")

// Only a live helper holds this name, which separates a running guard from a crashed one.
var guardOwnerName = `Global\Elarni-VPN-DNS-Guard`

func guardFilterKey(index uint32) windows.GUID {
	key := wfpGUID("32c5e95a-a632-4a10-9a9a-48d600000000")
	binary.BigEndian.PutUint32(key.Data4[4:], index)
	return key
}

// guardMarker tells the unelevated broker that this boot may hold a guard.
func guardMarker() string {
	root, err := windowsHelperRoot()
	if err != nil {
		return ""
	}
	return filepath.Join(root, ".dns-guard")
}

// A static session: its objects outlive this process until they are deleted,
// BFE stops or Windows restarts.
func openWFP() (uintptr, error) {
	name, _ := windows.UTF16PtrFromString("Elarni DNS")
	session := wfpSession{Display: wfpDisplay{Name: name, Description: name}, Timeout: 5000}
	var engine uintptr
	code, _, _ := wfpOpen.Call(0, 10, 0, uintptr(unsafe.Pointer(&session)), uintptr(unsafe.Pointer(&engine)))
	if code != 0 {
		return 0, syscall.Errno(code)
	}
	return engine, nil
}

// clearGuard deletes a guard inside the caller's transaction. Its filters are
// committed as one contiguous key range, so the first missing key ends it.
func clearGuard(engine uintptr) error {
	for index := uint32(0); ; index++ {
		key := guardFilterKey(index)
		code, _, _ := wfpDeleteFilter.Call(engine, uintptr(unsafe.Pointer(&key)))
		if uint32(code) == uint32(windows.FWP_E_FILTER_NOT_FOUND) {
			break
		}
		if code != 0 {
			return syscall.Errno(code)
		}
	}
	code, _, _ := wfpDeleteSublayer.Call(engine, uintptr(unsafe.Pointer(&guardSublayer)))
	if code != 0 && uint32(code) != uint32(windows.FWP_E_SUBLAYER_NOT_FOUND) {
		return syscall.Errno(code)
	}
	return nil
}

func releaseGuard() error {
	engine, err := openWFP()
	if err != nil {
		return err
	}
	defer wfpClose.Call(engine)
	if code, _, _ := wfpBegin.Call(engine, 0); code != 0 {
		return syscall.Errno(code)
	}
	if err := clearGuard(engine); err != nil {
		wfpAbort.Call(engine)
		return err
	}
	if code, _, _ := wfpCommit.Call(engine); code != 0 {
		return syscall.Errno(code)
	}
	_ = os.Remove(guardMarker())
	return nil
}

// Only an elevated helper can give the event this owner; any user may wait on
// it and read the owner, which tells a helper's event from a squatter's.
const guardOwnerSDDL = "O:BAD:(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x120000;;;WD)"

func helperOwnsGuard(event windows.Handle) bool {
	info, err := windows.GetSecurityInfo(event, windows.SE_KERNEL_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		return false
	}
	owner, _, err := info.Owner()
	return err == nil && (owner.IsWellKnown(windows.WinBuiltinAdministratorsSid) || owner.IsWellKnown(windows.WinLocalSystemSid))
}

// claimGuard fails with ERROR_ALREADY_EXISTS while another live helper (another
// Windows user's connection) owns the machine-wide guard. Any program can create
// the name, so one a helper did not create blocks nothing.
func claimGuard() (windows.Handle, error) {
	name, _ := windows.UTF16PtrFromString(guardOwnerName)
	sd, err := windows.SecurityDescriptorFromString(guardOwnerSDDL)
	if err != nil {
		return 0, err
	}
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	owner, err := windows.CreateEvent(&attributes, 1, 0, name)
	switch {
	case err == nil:
		return owner, nil
	case errors.Is(err, windows.ERROR_ALREADY_EXISTS) && helperOwnsGuard(owner):
		windows.CloseHandle(owner)
		return 0, err
	case errors.Is(err, windows.ERROR_ALREADY_EXISTS), errors.Is(err, windows.ERROR_ACCESS_DENIED), errors.Is(err, windows.ERROR_INVALID_HANDLE):
		// shortcut: while the name is squatted, two users' helpers are not kept apart; a private namespace would fix that.
		return owner, nil
	}
	return 0, err
}

// clearStaleGuard runs elevated for Repair; a live helper's guard is left alone.
func clearStaleGuard(release func() error) error {
	owner, err := claimGuard()
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		return nil
	}
	if err != nil {
		return err
	}
	defer windows.CloseHandle(owner)
	return release()
}

// staleGuard reports, without elevation, whether a helper that ended during
// this boot may have left its guard behind.
func staleGuard() bool {
	info, err := os.Stat(guardMarker())
	if err != nil || time.Since(info.ModTime()) > windows.DurationSinceBoot() {
		return false
	}
	return !liveGuard()
}

// liveGuard needs no elevation. A name it cannot open is not a helper's, and the
// elevated clear checks again before it releases anything.
func liveGuard() bool {
	name, _ := windows.UTF16PtrFromString(guardOwnerName)
	owner, err := windows.OpenEvent(windows.SYNCHRONIZE|windows.READ_CONTROL, false, name)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(owner)
	return helperOwnsGuard(owner)
}

// clearVPNGuard backs Repair and the first connect after a helper crash, and asks
// for consent only when a guard may remain.
func clearVPNGuard() (any, error) {
	if !staleGuard() {
		return map[string]any{}, nil
	}
	if _, err := askVPNService(serviceRequest{Action: "clearGuard"}); err == nil {
		return map[string]any{}, nil
	}
	helper, err := windowsHelper()
	if err != nil {
		return nil, err
	}
	if err := runElevated(helper, "--clear-guard"); err != nil {
		return nil, err
	}
	return map[string]any{}, nil
}

// The guard outlives a crashed helper, so a crash blocks DNS instead of leaking
// it until a helper removes it or Windows restarts. Physical DNS settings stay intact.
// The caller holds claimGuard's owner handle for as long as the guard may exist.
func protectDNS(luid uint64, protected []netip.Prefix) (func(), error) {
	failed := errors.New("dns_guard_failed")
	if unsafe.Sizeof(wfpFilter{}) != 200 || unsafe.Sizeof(wfpSession{}) != 72 || unsafe.Sizeof(wfpCondition{}) != 40 {
		return nil, failed
	}
	engine, err := openWFP()
	if err != nil {
		return nil, err
	}
	defer wfpClose.Call(engine)
	name, _ := windows.UTF16PtrFromString("Elarni DNS")
	display := wfpDisplay{Name: name, Description: name}
	executable, err := os.Executable()
	if err != nil {
		return nil, failed
	}
	path, _ := windows.UTF16PtrFromString(executable)
	var appID *wfpBlob
	code, _, _ := wfpAppID.Call(uintptr(unsafe.Pointer(path)), uintptr(unsafe.Pointer(&appID)))
	if code != 0 {
		return nil, syscall.Errno(code)
	}
	defer wfpFree.Call(uintptr(unsafe.Pointer(&appID)))
	sublayer := wfpSublayer{Key: guardSublayer, Display: display, Weight: 65535}
	code, _, _ = wfpBegin.Call(engine, 0)
	if code != 0 {
		return nil, syscall.Errno(code)
	}
	complete := false
	defer func() {
		if !complete {
			wfpAbort.Call(engine)
		}
	}()
	if err := clearGuard(engine); err != nil { // A crashed helper's leftovers.
		return nil, err
	}
	code, _, _ = wfpAddSublayer.Call(engine, uintptr(unsafe.Pointer(&sublayer)), 0)
	if code != 0 {
		return nil, syscall.Errno(code)
	}
	remotePort := wfpGUID("c35a604d-d22b-4e1a-91b4-68f674ee674b")
	protocol := wfpGUID("3971ef2b-623e-4f9a-8cb1-6e79b806b9a7")
	localInterface := wfpGUID("4cd62a49-59c3-4969-b7f3-bda5d32890a4")
	application := wfpGUID("d78e1e87-8644-4ea5-9437-d809ecefc971")
	var pinned runtime.Pinner
	pinned.Pin(&luid)
	defer pinned.Unpin()
	var next uint32
	add := func(layer windows.GUID, conditions []wfpCondition, action uint32, weight uintptr) error {
		filter := wfpFilter{Key: guardFilterKey(next), Display: display, Layer: layer, Sublayer: guardSublayer, Weight: wfpValue{Type: 1, Value: weight},
			Count: uint32(len(conditions)), Conditions: &conditions[0], Action: wfpAction{Type: action}}
		code, _, _ := wfpAddFilter.Call(engine, uintptr(unsafe.Pointer(&filter)), 0, 0)
		runtime.KeepAlive(conditions)
		if code != 0 {
			return syscall.Errno(code)
		}
		next++
		return nil
	}
	for _, layer := range []windows.GUID{wfpGUID("c38d57d1-05a7-4c33-904f-7fbceee60e82"), wfpGUID("4a72393b-319f-44bc-84c3-ba54dcb3b6b4")} {
		if len(protected) > 0 {
			if err := add(layer, []wfpCondition{{Field: application, Value: wfpValue{Type: 12, Value: uintptr(unsafe.Pointer(appID))}}}, 0x1002, 2); err != nil {
				return nil, err
			}
		}
		for _, proto := range []uintptr{6, 17} {
			for _, permit := range []bool{true, false} {
				conditions := []wfpCondition{{Field: remotePort, Value: wfpValue{Type: 2, Value: 53}},
					{Field: protocol, Value: wfpValue{Type: 1, Value: proto}}}
				action, weight := uint32(0x1001), uintptr(1)
				if permit {
					action = 0x1002
					weight = 2
					conditions = append(conditions, wfpCondition{Field: application, Value: wfpValue{Type: 12, Value: uintptr(unsafe.Pointer(appID))}})
				} else {
					conditions = append(conditions, wfpCondition{Field: localInterface, Match: 10 /* FWP_MATCH_NOT_EQUAL */, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}})
				}
				if err := add(layer, conditions, action, weight); err != nil {
					return nil, err
				}
			}
		}
	}
	for _, prefix := range protected {
		layer := wfpGUID("c38d57d1-05a7-4c33-904f-7fbceee60e82")
		var v4 [2]uint32
		var v6 struct {
			Address [16]byte
			Bits    uint8
		}
		var pin runtime.Pinner
		value := wfpValue{Type: 0x100}
		if prefix.Addr().Is4() {
			address := prefix.Addr().As4()
			v4 = [2]uint32{binary.BigEndian.Uint32(address[:]), ^uint32(0) << (32 - prefix.Bits())}
			pin.Pin(&v4)
			value.Value = uintptr(unsafe.Pointer(&v4))
		} else {
			layer = wfpGUID("4a72393b-319f-44bc-84c3-ba54dcb3b6b4")
			v6.Address, v6.Bits = prefix.Addr().As16(), uint8(prefix.Bits())
			pin.Pin(&v6)
			value.Type, value.Value = 0x101, uintptr(unsafe.Pointer(&v6))
		}
		conditions := []wfpCondition{
			{Field: wfpGUID("b235ae9a-1d64-49b8-a44c-5ff3d9095045"), Value: value},
			{Field: localInterface, Match: 10, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}},
		}
		err := add(layer, conditions, 0x1001, 1)
		pin.Unpin()
		if err != nil {
			return nil, err
		}
	}
	runtime.KeepAlive(appID)
	// Written first, so a crash right after the commit still leaves it for Repair.
	// Rewriting an empty marker left by an earlier boot may keep its old time.
	if marker := guardMarker(); os.WriteFile(marker, nil, 0o644) == nil {
		now := time.Now()
		_ = os.Chtimes(marker, now, now)
	}
	code, _, _ = wfpCommit.Call(engine)
	if code != 0 {
		return nil, syscall.Errno(code)
	}
	complete = true
	return func() {
		_ = releaseGuard() // On failure the marker stays, so Repair can retry.
	}, nil
}
