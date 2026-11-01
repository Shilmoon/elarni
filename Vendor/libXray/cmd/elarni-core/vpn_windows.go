//go:build windows

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/xtls/libxray/share"
	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

const vpnPipePrefix = `\\.\pipe\Elarni-VPN-`

var vpnBroker struct {
	sync.Mutex
	pipe    *os.File
	process windows.Handle
	closed  bool
	metrics *xray.RuntimeMetrics
	replies chan vpnReply
}

type vpnRequest struct {
	Config            string                    `json:"configJSON"`
	AssetRevision     string                    `json:"assetRevision"`
	MemoryLimitMB     int                       `json:"memoryLimitMB"`
	StreamMetrics     bool                      `json:"streamMetrics"`
	LogLevel          string                    `json:"logLevel"`
	ReuseSession      bool                      `json:"reuseSession"`
	TCPMaxConnections int                       `json:"tcpMaxConnections"`
	UDPMaxConnections int                       `json:"udpMaxConnections"`
	RoutePolicy       *share.WindowsRoutePolicy `json:"routePolicy"`
	RecordDiagnostics bool                      `json:"recordDiagnostics"`
}
type vpnHandshake struct {
	Version           int                       `json:"version"`
	Action            string                    `json:"action,omitempty"`
	Config            string                    `json:"config"`
	Assets            map[string]int            `json:"assets"`
	MemoryLimitMB     int                       `json:"memoryLimitMB"`
	LogLevel          string                    `json:"logLevel,omitempty"`
	TCPMaxConnections int                       `json:"tcpMaxConnections"`
	UDPMaxConnections int                       `json:"udpMaxConnections"`
	RoutePolicy       *share.WindowsRoutePolicy `json:"routePolicy"`
	RecordDiagnostics bool                      `json:"recordDiagnostics"`
}

type vpnReply struct {
	Ready   bool                 `json:"ready"`
	Adapter string               `json:"adapter,omitempty"`
	Error   string               `json:"error,omitempty"`
	Metrics *xray.RuntimeMetrics `json:"metrics,omitempty"`
	Logs    []xray.LogEntry      `json:"logs,omitempty"`
}

// SHELLEXECUTEINFOW is pointer-aligned by Go on the supported Windows x64 build.
type shellExecuteInfo struct {
	Size                              uint32
	Mask                              uint32
	Window                            windows.Handle
	Verb, File, Parameters, Directory *uint16
	Show                              int32
	Instance                          windows.Handle
	IDList                            uintptr
	Class                             *uint16
	ClassKey                          windows.Handle
	HotKey                            uint32
	Icon                              windows.Handle
	Process                           windows.Handle
}

func elevate(pipe string) (windows.Handle, error) {
	helper, err := windowsHelper()
	if err != nil {
		return 0, err
	}
	// The VPN service, where an administrator allowed this account, starts the
	// same helper without a prompt; anything else it says falls back to the prompt.
	start := serviceRequest{Action: "start", Pipe: pipe}
	reply, err := askVPNService(start)
	if err != nil && err.Error() == "vpn_service_outdated" {
		// It runs another build's helper. Pointing it at this one takes the prompt
		// this connect asks for anyway, and later connects ask none.
		if err := runElevated(helper, "--install-helper"); err != nil {
			return 0, err
		}
		reply, err = askVPNService(start)
	}
	if err == nil {
		return windows.Handle(reply.Handle), nil
	}
	// Only process identity crosses the command line; configuration uses the pipe.
	return shellRunAs(helper, "--vpn-child "+pipe+" "+strconv.Itoa(os.Getpid()))
}

func writeFrame(writer io.Writer, value any) error {
	data, err := json.Marshal(value)
	if err != nil || len(data) > maxMessage {
		return errors.New("invalid_vpn_request")
	}
	if err := binary.Write(writer, binary.LittleEndian, uint32(len(data))); err != nil {
		return err
	}
	_, err = io.Copy(writer, bytes.NewReader(data))
	return err
}
func readFrame(reader io.Reader, value any) error {
	var length uint32
	if binary.Read(reader, binary.LittleEndian, &length) != nil || length == 0 || length > maxMessage {
		return errors.New("invalid_vpn_request")
	}
	data := make([]byte, length)
	if _, err := io.ReadFull(reader, data); err != nil {
		return errors.New("invalid_vpn_request")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return errors.New("invalid_vpn_request")
	}
	return nil
}

func runVPN(payload json.RawMessage) (any, error) {
	var request vpnRequest
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || request.MemoryLimitMB < 0 || request.MemoryLimitMB > 4096 ||
		request.TCPMaxConnections < 0 || request.TCPMaxConnections > 4096 || request.UDPMaxConnections < 0 || request.UDPMaxConnections > 4096 ||
		request.LogLevel != "" && xray.SetLogLevel(request.LogLevel) != nil {
		return nil, errors.New("invalid_vpn_request")
	}
	// Validate before consent and again inside the elevated process.
	if _, err := share.WindowsTunnelConfig([]byte(request.Config), "elarni-validation", request.RoutePolicy); err != nil {
		return nil, err
	}
	root, err := os.UserCacheDir()
	if err != nil {
		return nil, errors.New("assets_unavailable")
	}
	assets, err := readAssets(filepath.Join(root, "Elarni", "assets"), request.AssetRevision)
	if err != nil {
		return nil, err
	}
	if !platformRunning() {
		if err := connectVPN(); err != nil {
			return nil, err
		}
	}
	vpnBroker.Lock()
	pipe, process, replies := vpnBroker.pipe, vpnBroker.process, vpnBroker.replies
	vpnBroker.metrics = nil
	vpnBroker.Unlock()
	if pipe == nil {
		return nil, errors.New("cancelled")
	}
	sizes := map[string]int{}
	for name, data := range assets {
		sizes[name] = len(data)
	}
	if err = writeFrame(pipe, vpnHandshake{Version: 1, Config: request.Config, Assets: sizes, MemoryLimitMB: request.MemoryLimitMB,
		LogLevel: request.LogLevel, TCPMaxConnections: request.TCPMaxConnections, UDPMaxConnections: request.UDPMaxConnections, RoutePolicy: request.RoutePolicy,
		RecordDiagnostics: request.RecordDiagnostics}); err != nil {
		platformStop()
		return nil, errors.New("vpn_failed")
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if data := assets[name]; data != nil {
			if _, err = io.Copy(pipe, bytes.NewReader(data)); err != nil {
				platformStop()
				return nil, errors.New("vpn_failed")
			}
		}
	}
	reply, ok := <-replies
	if !ok || !reply.Ready {
		platformStop()
		if strings.HasPrefix(reply.Error, "vpn_") && len(reply.Error) < 96 {
			return nil, errors.New(reply.Error)
		}
		return nil, errors.New("vpn_failed")
	}
	expected, err := windows.GetProcessId(process)
	if err != nil {
		return nil, errors.New("vpn_failed")
	}
	return map[string]any{"adapter": reply.Adapter, "helperPid": expected}, nil
}

func stopVPN() (any, error) {
	vpnBroker.Lock()
	pipe, replies := vpnBroker.pipe, vpnBroker.replies
	vpnBroker.metrics = nil
	vpnBroker.Unlock()
	if pipe == nil {
		return nil, errors.New("vpn_failed")
	}
	if writeFrame(pipe, vpnHandshake{Version: 1, Action: "stop"}) != nil {
		return nil, errors.New("vpn_failed")
	}
	select {
	case reply, ok := <-replies:
		if ok && reply.Ready {
			return map[string]any{}, nil
		}
	case <-time.After(8 * time.Second):
	}
	platformStop()
	return nil, errors.New("vpn_failed")
}

func connectVPN() error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return errors.New("vpn_peer_rejected")
	}
	security, err := windows.SecurityDescriptorFromString("D:P(A;;GA;;;" + user.User.Sid.String() + ")(A;;GA;;;BA)(A;;GA;;;SY)")
	if err != nil {
		return errors.New("vpn_peer_rejected")
	}
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return errors.New("vpn_failed")
	}
	name := vpnPipePrefix + hex.EncodeToString(random[:])
	pipeName, _ := windows.UTF16PtrFromString(name)
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: security}
	handle, err := windows.CreateNamedPipe(pipeName, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, &sa)
	if err != nil {
		return errors.New("vpn_failed")
	}
	pipe := os.NewFile(uintptr(handle), "elarni-vpn-pipe")
	vpnBroker.Lock()
	if vpnBroker.closed {
		vpnBroker.Unlock()
		pipe.Close()
		return errors.New("cancelled")
	}
	vpnBroker.pipe = pipe
	vpnBroker.metrics = nil
	vpnBroker.Unlock()
	connected := make(chan error, 1)
	go func() {
		event, err := windows.CreateEvent(nil, 1, 0, nil)
		if err != nil {
			connected <- err
			return
		}
		defer windows.CloseHandle(event)
		// This connect uses its own event, not Go's pipe I/O completion queue.
		// The kernel keeps this pointer while I/O is pending; pinning moves it off the
		// goroutine stack, which may be copied when it grows.
		overlap := &windows.Overlapped{HEvent: event | 1}
		var pin runtime.Pinner
		pin.Pin(overlap)
		defer pin.Unpin()
		err = windows.ConnectNamedPipe(handle, overlap)
		if errors.Is(err, windows.ERROR_IO_PENDING) {
			var transferred uint32
			err = windows.GetOverlappedResult(handle, overlap, &transferred, true)
		}
		if errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
			err = nil
		}
		connected <- err
	}()
	process, err := elevate(name)
	if err != nil {
		platformStop()
		return err
	}
	vpnBroker.Lock()
	closed := vpnBroker.closed
	if !closed {
		vpnBroker.process = process
	}
	vpnBroker.Unlock()
	if closed {
		windows.TerminateProcess(process, 1)
		windows.CloseHandle(process)
		return errors.New("cancelled")
	}
	select {
	case err = <-connected:
	case <-time.After(15 * time.Second):
		err = errors.New("vpn_peer_rejected")
	}
	if err != nil {
		platformStop()
		return errors.New("vpn_peer_rejected")
	}
	var peer uint32
	expected, err := windows.GetProcessId(process)
	if err != nil || windows.GetNamedPipeClientProcessId(handle, &peer) != nil || peer != expected {
		platformStop()
		return errors.New("vpn_peer_rejected")
	}
	replies := make(chan vpnReply, 1)
	vpnBroker.Lock()
	vpnBroker.replies = replies
	vpnBroker.Unlock()
	go func() {
		defer close(replies)
		for {
			var reply vpnReply
			if readFrame(pipe, &reply) != nil {
				return
			}
			if reply.Metrics != nil {
				vpnBroker.Lock()
				if vpnBroker.pipe == pipe && !vpnBroker.closed {
					vpnBroker.metrics = reply.Metrics
					xray.AppendLogs(reply.Logs)
				}
				vpnBroker.Unlock()
			} else {
				select {
				case replies <- reply:
				default:
					return
				}
			}
		}
	}()
	return nil
}

func platformMetrics() (xray.RuntimeMetrics, error) {
	vpnBroker.Lock()
	defer vpnBroker.Unlock()
	if vpnBroker.closed || vpnBroker.metrics == nil {
		return xray.RuntimeMetrics{}, errors.New("not_running")
	}
	return *vpnBroker.metrics, nil
}

func platformRunning() bool {
	vpnBroker.Lock()
	process := vpnBroker.process
	closed := vpnBroker.closed
	vpnBroker.Unlock()
	if closed || process == 0 {
		return false
	}
	state, err := windows.WaitForSingleObject(process, 0)
	return err == nil && state == uint32(windows.WAIT_TIMEOUT)
}
func platformStop() error {
	vpnBroker.Lock()
	if vpnBroker.closed {
		vpnBroker.Unlock()
		return nil
	}
	vpnBroker.closed = true
	pipe, process := vpnBroker.pipe, vpnBroker.process
	vpnBroker.pipe = nil
	vpnBroker.process = 0
	vpnBroker.metrics = nil
	vpnBroker.Unlock()
	if pipe != nil {
		windows.CancelIoEx(windows.Handle(pipe.Fd()), nil)
		windows.DisconnectNamedPipe(windows.Handle(pipe.Fd()))
		pipe.Close()
	}
	if process != 0 {
		defer windows.CloseHandle(process)
		state, _ := windows.WaitForSingleObject(process, 5000)
		if state == uint32(windows.WAIT_TIMEOUT) {
			windows.TerminateProcess(process, 1)
			windows.WaitForSingleObject(process, 2000)
		}
	}
	return nil
}

func platformMain() (bool, int) {
	if len(os.Args) == 2 && (os.Args[1] == "--install-helper" || os.Args[1] == "--clear-guard" || os.Args[1] == "--uninstall-helper") {
		if !windows.GetCurrentProcessToken().IsElevated() {
			return true, 1
		}
		operation := installWindowsHelper
		if os.Args[1] == "--clear-guard" {
			operation = func() error { return clearStaleGuard(releaseGuard) }
		} else if os.Args[1] == "--uninstall-helper" {
			operation = uninstallWindowsHelper
		}
		if operation() != nil {
			return true, 1
		}
		return true, 0
	}
	if len(os.Args) == 3 && os.Args[1] == "--service" {
		return true, runVPNService(os.Args[2])
	}
	if len(os.Args) == 4 && os.Args[1] == "--vpn-service" && (os.Args[2] == "add" || os.Args[2] == "remove") {
		if !windows.GetCurrentProcessToken().IsElevated() || changeVPNService(os.Args[2] == "add", os.Args[3]) != nil {
			return true, 1
		}
		return true, 0
	}
	if len(os.Args) < 2 || os.Args[1] != "--vpn-child" {
		return false, 0
	}
	if len(os.Args) != 4 || !windows.GetCurrentProcessToken().IsElevated() {
		return true, 1
	}
	pid, err := strconv.ParseUint(os.Args[3], 10, 32)
	if err != nil || !strings.HasPrefix(os.Args[2], vpnPipePrefix) || !assetRevision.MatchString(strings.TrimPrefix(os.Args[2], vpnPipePrefix)) {
		return true, 1
	}
	return true, vpnChild(os.Args[2], uint32(pid))
}

func vpnChild(name string, brokerPID uint32) int {
	parent, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, brokerPID)
	if err != nil {
		return 1
	}
	defer windows.CloseHandle(parent)
	buffer := make([]uint16, 32768)
	length := uint32(len(buffer))
	executable, err := os.Executable()
	if err != nil || windows.QueryFullProcessImageName(parent, 0, &buffer[0], &length) != nil {
		return 1
	}
	// The broker runs this same build from its bundle; this is its protected copy.
	own, err := fileDigest(executable)
	broker, brokerErr := fileDigest(windows.UTF16ToString(buffer[:length]))
	if err != nil || brokerErr != nil || own != broker {
		return 1
	}
	pipeName, _ := windows.UTF16PtrFromString(name)
	// Anonymous SQOS prevents the unelevated pipe server impersonating this token.
	// Overlapped I/O lets the EOF watcher read while startup writes readiness.
	handle, err := windows.CreateFile(pipeName, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED|windows.SECURITY_SQOS_PRESENT|windows.SECURITY_ANONYMOUS, 0)
	if err != nil {
		return 1
	}
	pipe := os.NewFile(uintptr(handle), "elarni-vpn-child")
	defer pipe.Close()
	var peer uint32
	if windows.GetNamedPipeServerProcessId(handle, &peer) != nil || peer != brokerPID {
		return 1
	}
	commands := make(chan vpnCommand, 1)
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		for {
			command, err := readVPNCommand(pipe)
			if err != nil {
				return
			}
			select {
			case commands <- command:
			default:
				return
			}
		}
	}()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-closed:
			return 0
		case <-ticker.C:
			state, err := windows.WaitForSingleObject(parent, 0)
			if err != nil || state != uint32(windows.WAIT_TIMEOUT) {
				return 1
			}
		case command := <-commands:
			if command.Action != "stop" {
				if code := runVPNTunnel(pipe, parent, command, commands, closed); code != 0 {
					return code
				}
			}
			if writeFrame(pipe, vpnReply{Ready: true}) != nil {
				return 1
			}
		}
	}
}

type vpnCommand struct {
	vpnHandshake
	assets map[string][]byte
}

func readVPNCommand(pipe io.Reader) (vpnCommand, error) {
	request := vpnCommand{assets: map[string][]byte{}}
	if readFrame(pipe, &request.vpnHandshake) != nil || request.Version != 1 || (request.Action != "" && request.Action != "stop") ||
		len(request.Assets) > 2 || request.MemoryLimitMB < 0 || request.MemoryLimitMB > 4096 ||
		request.TCPMaxConnections < 0 || request.TCPMaxConnections > 4096 || request.UDPMaxConnections < 0 || request.UDPMaxConnections > 4096 {
		return request, errors.New("invalid_vpn_request")
	}
	for name, size := range request.Assets {
		if name != "geoip.dat" && name != "geosite.dat" || size <= 0 || size > 64*1024*1024 {
			return request, errors.New("invalid_vpn_request")
		}
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if size := request.Assets[name]; size > 0 {
			data := make([]byte, size)
			if _, err := io.ReadFull(pipe, data); err != nil {
				return request, err
			}
			request.assets[name] = data
		}
	}
	return request, nil
}

// tunnelAdapter is deterministic because Windows NLA keeps a network profile for
// every adapter GUID it sees. It is per Windows session because a Wintun adapter
// lives until its helper closes it or exits, so another user's helper needs its own GUID.
func tunnelAdapter(session uint32) string {
	return "elarni-tun-" + strconv.FormatUint(uint64(session), 10)
}

// tunnelInterface finds the adapter by its requested GUID. On a name clash
// Wintun renames one interface, so the name may belong to another one.
func tunnelInterface(guid *windows.GUID) (*winipcfg.MibIfRow2, error) {
	luid, err := winipcfg.LUIDFromGUID(guid)
	if err != nil {
		return nil, err
	}
	return luid.Interface()
}

func runVPNTunnel(pipe io.Writer, parent windows.Handle, request vpnCommand, commands <-chan vpnCommand, closed <-chan struct{}) (code int) {
	// Elevated by the same account, the child records into the user's own cache.
	defer startRecording(request.RecordDiagnostics, userRecordingDirectory(), 0)()
	recordRuntimeConfig(request.Config, request.MemoryLimitMB, request.TCPMaxConnections, request.UDPMaxConnections, true)
	if flightrecorder.Enabled() {
		version := windows.RtlGetVersion()
		flightrecorder.Record(flightrecorder.Event{Name: "windows_vpn_start", Values: map[string]int64{"parent_pid": int64(os.Getppid()), "windows_major": int64(version.MajorVersion), "windows_minor": int64(version.MinorVersion), "windows_build": int64(version.BuildNumber)}})
		defer func() {
			flightrecorder.Record(flightrecorder.Event{Name: "windows_vpn_stop", Values: map[string]int64{"exit_code": int64(code)}})
		}()
	}
	fail := func(stage string, err error) int {
		code := "vpn_" + stage + "_failed"
		var native syscall.Errno
		if errors.As(err, &native) {
			code += "_" + strconv.FormatUint(uint64(native), 10)
		}
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "windows_vpn_failure", Code: code, Values: map[string]int64{"native_error": int64(native)}})
		}
		writeFrame(pipe, map[string]any{"ready": false, "error": code})
		return 1
	}
	if installAssets(request.assets) != nil {
		return fail("assets", nil)
	}
	filesystem.NewFileReader = func(string) (io.ReadCloser, error) { return nil, errors.New("file_access_denied") }
	// The broker's session: a runas child shares it, the service's child runs in session 0.
	var session uint32
	broker, err := windows.GetProcessId(parent)
	if err == nil {
		err = windows.ProcessIdToSessionId(broker, &session)
	}
	if err != nil {
		return fail("adapter", err)
	}
	adapter := tunnelAdapter(session)
	config, err := share.WindowsTunnelConfig([]byte(request.Config), adapter, request.RoutePolicy)
	if err != nil {
		writeFrame(pipe, map[string]any{"ready": false, "error": "invalid_vpn_config"})
		return 1
	}
	// Claimed before any route or adapter exists, so another user's live helper
	// keeps the machine untouched; held until the deferred DNS release has run.
	owner, err := claimGuard()
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		writeFrame(pipe, map[string]any{"ready": false, "error": "vpn_guard_busy"})
		return 1
	}
	if err != nil {
		return fail("dns", err)
	}
	defer windows.CloseHandle(owner)
	if err = bindPhysicalRoutes(); err != nil {
		return fail("routes", err)
	}
	wintun, err := bundledWintun()
	if err == nil {
		err = loadPinnedWintun(wintun)
	}
	if err != nil {
		return fail("wintun", err)
	}
	if request.LogLevel != "" && xray.SetLogLevel(request.LogLevel) != nil {
		writeFrame(pipe, map[string]any{"ready": false, "error": "invalid_vpn_config"})
		return 1
	}
	logCursor := xray.LastLogSeq()
	started := make(chan error, 1)
	tun.SetSessionLimits(request.TCPMaxConnections, request.UDPMaxConnections)
	if request.MemoryLimitMB > 0 {
		xray.SetMemoryLimit(int64(request.MemoryLimitMB) * 1024 * 1024)
	} else {
		xray.SetMemoryLimit(math.MaxInt64)
	}
	// Deferred before the core's stop so DNS stays blocked until the tunnel is gone.
	// With Block traffic without VPN, only a requested stop lifts it: after any other
	// exit the guard blocks traffic until the next connect or Repair VPN setup.
	var releaseDNS func()
	defer func() {
		if releaseDNS != nil && (code == 0 || request.RoutePolicy == nil || !request.RoutePolicy.BlockWithoutVPN) {
			releaseDNS()
		}
	}()
	go func() { started <- xray.RunXrayFromJSON(string(config)) }()
	defer func() {
		done := make(chan error, 1)
		go func() { done <- xray.StopXray() }()
		select {
		case err := <-done:
			if err != nil {
				code = 1
			} else {
				// The elevated owner survives disconnect; raw geodata need not.
				filesystem.NewAssetReader = nil
			}
		case <-time.After(2 * time.Second):
			code = 1 // Never reuse globals while a previous runtime is stopping.
		}
	}()
	select {
	case err = <-started:
	case <-closed:
		return 1
	case <-time.After(30 * time.Second):
		if flightrecorder.Enabled() {
			flightrecorder.Record(flightrecorder.Event{Name: "windows_vpn_failure", Code: "startup_timeout"})
		}
		return 1
	}
	if err != nil {
		return fail("core", err)
	}
	iface, err := tunnelInterface(tun.AdapterGUID(adapter))
	if err != nil {
		return fail("adapter", err)
	}
	protected, err := share.WindowsProtectedRoutes(request.RoutePolicy)
	if err != nil {
		return fail("routes", err)
	}
	guard, err := protectDNS(uint64(iface.InterfaceLUID), protected)
	if err != nil {
		return fail("dns", err)
	}
	releaseDNS = guard
	if flightrecorder.Enabled() {
		flightrecorder.Record(flightrecorder.Event{Name: "windows_vpn_ready", Values: map[string]int64{"interface_index": int64(iface.InterfaceIndex)}})
	}
	if writeFrame(pipe, map[string]any{"ready": true, "adapter": iface.Alias()}) != nil {
		return 1
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-closed:
			return 1
		case command := <-commands:
			if command.Action != "stop" {
				return 1
			}
			return 0
		case <-ticker.C:
			state, err := windows.WaitForSingleObject(parent, 0)
			if err != nil || state != uint32(windows.WAIT_TIMEOUT) || !xray.GetXrayState() {
				return 1
			}
			// A disabled or removed adapter carries nothing while the core keeps running.
			if current, err := iface.InterfaceLUID.Interface(); err != nil || current.OperStatus != winipcfg.IfOperStatusUp {
				return 1
			}
			if metrics, err := xray.GetRuntimeMetrics(); err == nil {
				logs := xray.ReadLogs(logCursor).Entries
				if len(logs) > 0 {
					logCursor = logs[len(logs)-1].Seq
				}
				if writeFrame(pipe, vpnReply{Metrics: &metrics, Logs: logs}) != nil {
					return 1
				}
			}
		}
	}
}
