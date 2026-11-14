//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/xtls/libxray/geo"
	"github.com/xtls/libxray/share"
	"github.com/xtls/libxray/xray"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"github.com/xtls/xray-core/proxy/tun"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/unix"
)

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
type linuxCommand struct {
	Action string `json:"action"`
	// Hold marks a stop the app follows with another start: with Block traffic without
	// VPN the kill switch stays in place between the two tunnels.
	Hold       bool           `json:"hold,omitempty"`
	Request    vpnRequest     `json:"request"`
	Network    linuxNetwork   `json:"network"`
	Owner      int            `json:"owner"` // Set by the supervisor: the user the worker records for.
	AssetSizes map[string]int `json:"assets"`
	assets     map[string][]byte
}

const linuxRecordingRoot = "/var/log/elarni"

func linuxRecordingDirectory(uid int) string {
	return filepath.Join(linuxRecordingRoot, strconv.Itoa(uid))
}

// prepareLinuxRecording gives the user their own directory under a root-owned parent,
// so they can read and mark the recording but cannot swap the directory for a link.
func prepareLinuxRecording(uid int) string {
	if err := os.Mkdir(linuxRecordingRoot, 0755); err != nil && !errors.Is(err, os.ErrExist) {
		return ""
	}
	info, err := os.Lstat(linuxRecordingRoot)
	if err != nil || !info.IsDir() || info.Sys().(*syscall.Stat_t).Uid != 0 || os.Chmod(linuxRecordingRoot, 0755) != nil {
		return ""
	}
	directory := linuxRecordingDirectory(uid)
	if err := os.Mkdir(directory, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return ""
	}
	if info, err := os.Lstat(directory); err != nil || !info.IsDir() || os.Lchown(directory, uid, -1) != nil {
		return ""
	}
	return directory
}

type linuxReply struct {
	Ready   bool                 `json:"ready"`
	Error   string               `json:"error,omitempty"`
	Adapter string               `json:"adapter,omitempty"`
	PID     int                  `json:"helperPid,omitempty"`
	Metrics *xray.RuntimeMetrics `json:"metrics,omitempty"`
	Logs    []xray.LogEntry      `json:"logs,omitempty"`
	// The connections view's entries that changed since the last frame.
	Connections *xray.ConnectionsResult `json:"connections,omitempty"`
	Lost        bool                    `json:"lost,omitempty"` // the tunnel ended without a stop; its supervisor waits
}
type linuxChild struct {
	command *exec.Cmd
	input   io.WriteCloser
	replies chan linuxReply
	done    chan struct{}
	err     error       // published by closing done
	up      atomic.Bool // a started tunnel that was neither stopped nor lost, in pipe order
}

var linuxBroker struct {
	sync.Mutex
	child   *linuxChild
	closed  bool
	metrics *xray.RuntimeMetrics
}

func linuxReadFrame(reader io.Reader, target any) error {
	var length uint32
	if err := binary.Read(reader, binary.LittleEndian, &length); err != nil {
		return err
	}
	if length == 0 || length > maxMessage {
		return errors.New("invalid_request")
	}
	// Grows with the bytes that arrive, so a declared size alone reserves no memory.
	data, err := io.ReadAll(io.LimitReader(reader, int64(length)))
	if err != nil {
		return err
	}
	if len(data) != int(length) {
		return io.ErrUnexpectedEOF
	}
	return decodeLinuxJSON(data, target)
}
func linuxWriteFrame(writer io.Writer, value any) error {
	data, err := json.Marshal(value)
	if err != nil || len(data) > maxMessage {
		return errors.New("invalid_request")
	}
	var buffer bytes.Buffer
	if err := binary.Write(&buffer, binary.LittleEndian, uint32(len(data))); err != nil {
		return err
	}
	buffer.Write(data)
	_, err = io.Copy(writer, &buffer)
	return err
}
func linuxReadCommand(reader io.Reader) (linuxCommand, error) {
	var command linuxCommand
	if linuxReadFrame(reader, &command) != nil || (command.Action != "start" && command.Action != "stop") || len(command.AssetSizes) > 2 {
		return command, errors.New("invalid_request")
	}
	command.assets = map[string][]byte{}
	for name, size := range command.AssetSizes {
		if (name != "geoip.dat" && name != "geosite.dat") || size <= 0 || size > geo.MaxFileBytes {
			return command, errors.New("invalid_assets")
		}
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if size := command.AssetSizes[name]; size > 0 {
			data := make([]byte, size)
			if _, err := io.ReadFull(reader, data); err != nil {
				return command, err
			}
			command.assets[name] = data
		}
	}
	return command, nil
}
func linuxWriteCommand(writer io.Writer, command linuxCommand) error {
	command.AssetSizes = map[string]int{}
	for name, data := range command.assets {
		command.AssetSizes[name] = len(data)
	}
	if err := linuxWriteFrame(writer, command); err != nil {
		return err
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if data := command.assets[name]; len(data) != 0 {
			if _, err := io.Copy(writer, bytes.NewReader(data)); err != nil {
				return err
			}
		}
	}
	return nil
}
func validLinuxRequest(request vpnRequest) error {
	if err := validLinuxLimits(request); err != nil {
		return err
	}
	_, err := linuxTunnelConfig([]byte(request.Config), linuxNetwork{Name: "rvvalidate", DNSPort: 5353}, request.RoutePolicy)
	return err
}

// validLinuxLimits checks what building the tunnel config does not.
func validLinuxLimits(request vpnRequest) error {
	if request.MemoryLimitMB < 0 || request.MemoryLimitMB > 4096 || request.TCPMaxConnections < 0 || request.TCPMaxConnections > 4096 || request.UDPMaxConnections < 0 || request.UDPMaxConnections > 4096 ||
		request.LogLevel != "" && xray.SetLogLevel(request.LogLevel) != nil {
		return errors.New("invalid_vpn_request")
	}
	return nil
}

func startLinuxChild(command *exec.Cmd, events func(linuxReply)) (*linuxChild, error) {
	input, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	// Diagnostics from a privileged process never expose config or credentials.
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		input.Close()
		output.Close()
		return nil, err
	}
	child := &linuxChild{command: command, input: input, replies: make(chan linuxReply, 1), done: make(chan struct{})}
	go func() {
		defer func() {
			input.Close()
			output.Close()
			child.err = command.Wait()
			close(child.done)
			close(child.replies)
		}()
		for {
			var reply linuxReply
			if linuxReadFrame(output, &reply) != nil {
				break
			}
			// Metrics, log lines, connections and a tunnel loss are events, not replies.
			if reply.Metrics != nil || len(reply.Logs) > 0 || reply.Connections != nil || reply.Lost {
				if reply.Lost {
					child.up.Store(false)
				}
				if events != nil {
					events(reply)
				}
				continue
			}
			child.up.Store(reply.Ready && reply.Adapter != "")
			select {
			case child.replies <- reply:
			default:
				output.Close()
				input.Close()
				return
			}
		}
	}()
	return child, nil
}
func (child *linuxChild) exitedWith(exit **exec.ExitError) bool {
	select {
	case <-child.done:
		return errors.As(child.err, exit)
	default:
		return false
	}
}
func (child *linuxChild) stop() error {
	child.input.Close()
	select {
	case <-child.done:
		if child.err != nil {
			return errors.New("vpn_cleanup_failed")
		}
		return nil
	case <-time.After(5 * time.Second):
		// Only the root supervisor can kill its root worker. An unelevated launcher
		// closes both ownership pipes; the supervisor then reaps the worker itself.
		_ = child.command.Process.Kill()
		select {
		case <-child.done:
			return errors.New("vpn_cleanup_failed")
		case <-time.After(3 * time.Second):
			return errors.New("vpn_cleanup_failed")
		}
	}
}
func (child *linuxChild) request(command linuxCommand, timeout time.Duration) (linuxReply, error) {
	sent := make(chan error, 1)
	go func() { sent <- linuxWriteCommand(child.input, command) }()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-sent:
		if err != nil {
			return linuxReply{}, errors.New("vpn_failed")
		}
	case <-child.done:
		return linuxReply{}, errors.New("vpn_failed")
	case <-timer.C:
		child.input.Close()
		return linuxReply{}, errors.New("vpn_timeout")
	}
	select {
	case reply, ok := <-child.replies:
		if !ok {
			return linuxReply{}, errors.New("vpn_failed")
		}
		if !reply.Ready {
			// Typed stage codes from the root helper never carry config or paths.
			if strings.HasPrefix(reply.Error, "vpn_") && len(reply.Error) < 96 {
				return reply, errors.New(reply.Error)
			}
			return reply, errors.New("vpn_failed")
		}
		return reply, nil
	case <-timer.C:
		child.input.Close()
		return linuxReply{}, errors.New("vpn_timeout")
	}
}
func runVPN(payload json.RawMessage) (any, error) {
	// The broker lives for the whole session; its geodata copies are garbage now.
	defer debug.FreeOSMemory()
	return startVPN(payload)
}

func startVPN(payload json.RawMessage) (any, error) {
	var request vpnRequest
	if decodeLinuxJSON(payload, &request) != nil {
		return nil, errors.New("invalid_vpn_request")
	}
	if err := validLinuxRequest(request); err != nil {
		return nil, err
	}
	root, err := linuxAssetRoot()
	if err != nil {
		return nil, err
	}
	assets, err := readAssets(root, request.AssetRevision)
	if err != nil {
		return nil, err
	}
	linuxBroker.Lock()
	idle := linuxBroker.child == nil
	linuxBroker.Unlock()
	var command *exec.Cmd
	if idle {
		executable, err := os.Executable()
		if err != nil {
			return nil, errors.New("native_unavailable")
		}
		command = exec.Command(executable, "--linux-supervisor")
		if os.Geteuid() != 0 {
			// Installing the helper waits for authentication; keep the broker unlocked.
			helper, err := linuxHelper(executable)
			if err != nil {
				return nil, err
			}
			command = exec.Command(linuxTool("pkexec", "/usr/bin", "/run/wrappers/bin"), helper, "--linux-supervisor")
		}
	}
	linuxBroker.Lock()
	child := linuxBroker.child
	if linuxBroker.closed {
		linuxBroker.Unlock()
		return nil, errors.New("cancelled")
	}
	// Only a stop clears the child, and it closes the broker too: a child seen above is still here.
	if child == nil {
		child, err = startLinuxChild(command, func(reply linuxReply) {
			linuxBroker.Lock()
			defer linuxBroker.Unlock()
			if linuxBroker.child != nil && !linuxBroker.closed {
				if reply.Metrics != nil || reply.Lost {
					linuxBroker.metrics = reply.Metrics
				}
				xray.AppendLogs(reply.Logs)
				relayedConnections.add(reply.Connections)
			}
		})
		if err != nil {
			linuxBroker.Unlock()
			return nil, errors.New("elevation_failed")
		}
		linuxBroker.child = child
	}
	linuxBroker.metrics = nil
	linuxBroker.Unlock()
	reply, err := child.request(linuxCommand{Action: "start", Request: request, assets: assets}, 110*time.Second)
	if err != nil {
		// A supervisor that answered failed only this tunnel and waits for the next connect.
		if reply.Error != "" && platformRunning() {
			return nil, err
		}
		_ = platformStop()
		var exit *exec.ExitError
		if !platformRunning() && child.exitedWith(&exit) && (exit.ExitCode() == 126 || exit.ExitCode() == 127) {
			return nil, errors.New("elevation_denied")
		}
		return nil, err
	}
	return map[string]any{"adapter": reply.Adapter, "helperPid": reply.PID}, nil
}
func stopVPN(payload json.RawMessage) (any, error) {
	var request struct {
		Hold bool `json:"hold"`
	}
	_ = json.Unmarshal(payload, &request)
	linuxBroker.Lock()
	child := linuxBroker.child
	linuxBroker.metrics = nil
	linuxBroker.Unlock()
	if child == nil {
		return map[string]any{}, nil
	}
	_, err := child.request(linuxCommand{Action: "stop", Hold: request.Hold}, 10*time.Second)
	if err != nil {
		_ = platformStop()
	}
	return map[string]any{}, err
}

// clearVPNGuard backs Repair and the first connect after a helper crash, and asks
// for consent only when a guard may remain.
func clearVPNGuard() (any, error) {
	if !linuxGuardLeft() {
		return map[string]any{}, nil
	}
	if os.Geteuid() == 0 {
		reapLinuxNetworks(linuxNetworkRecords, linuxNetwork.cleanup)
		return map[string]any{}, nil
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, errors.New("native_unavailable")
	}
	helper, err := linuxHelper(executable)
	if err != nil {
		return nil, err
	}
	err = exec.Command(linuxTool("pkexec", "/usr/bin", "/run/wrappers/bin"), helper, "--clear-guard").Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) && (exit.ExitCode() == 126 || exit.ExitCode() == 127) {
		return nil, errors.New("elevation_denied")
	}
	if err != nil {
		return nil, errors.New("vpn_cleanup_failed")
	}
	return map[string]any{}, nil
}
func platformRunning() bool {
	linuxBroker.Lock()
	defer linuxBroker.Unlock()
	if linuxBroker.closed || linuxBroker.child == nil {
		return false
	}
	select {
	case <-linuxBroker.child.done:
		return false
	default:
		return true
	}
}
func platformTunnelUp() bool {
	linuxBroker.Lock()
	defer linuxBroker.Unlock()
	return !linuxBroker.closed && linuxBroker.child != nil && linuxBroker.child.up.Load()
}
func platformStop() error {
	linuxBroker.Lock()
	child := linuxBroker.child
	linuxBroker.child = nil
	linuxBroker.closed = true
	linuxBroker.metrics = nil
	linuxBroker.Unlock()
	if child != nil {
		return child.stop()
	}
	return nil
}
func platformMetrics() (xray.RuntimeMetrics, error) {
	linuxBroker.Lock()
	defer linuxBroker.Unlock()
	if linuxBroker.metrics == nil {
		return xray.RuntimeMetrics{}, errors.New("not_running")
	}
	return *linuxBroker.metrics, nil
}

func platformMain() (bool, int) {
	if len(os.Args) != 2 {
		return false, 0
	}
	mode := os.Args[1]
	if mode != "--linux-supervisor" && mode != "--linux-worker" && mode != "--linux-probe" && mode != "--install-helper" && mode != "--clear-guard" {
		return false, 0
	}
	if os.Geteuid() != 0 {
		return true, 1
	}
	if mode == "--clear-guard" {
		// Only records whose supervisor died are released; a live tunnel keeps its guard.
		reapLinuxNetworks(linuxNetworkRecords, linuxNetwork.cleanup)
		return true, 0
	}
	if mode == "--install-helper" {
		if installLinuxHelper() != nil {
			return true, 1
		}
		return true, 0
	}
	output := os.Stdout
	os.Stdout = os.Stderr
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer cancel()
	if mode == "--linux-probe" {
		return true, linuxProbeChild(ctx, os.Stdin, output)
	}
	if mode == "--linux-worker" {
		return true, linuxWorker(ctx, os.Stdin, output)
	}
	return true, linuxSupervisor(ctx, os.Stdin, output)
}

func linuxCommands(ctx context.Context, input io.Reader) (<-chan linuxCommand, <-chan struct{}) {
	commands := make(chan linuxCommand)
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		reader := bufio.NewReader(input)
		for {
			command, err := linuxReadCommand(reader)
			if err != nil {
				return
			}
			select {
			case commands <- command:
			case <-ctx.Done():
				return
			}
		}
	}()
	return commands, closed
}

// pinnedLinuxExecutable keeps open the binary pkexec approved, so a user who can
// write its path (portable bundle in $HOME) cannot swap what root runs next.
func pinnedLinuxExecutable() (*os.File, string, error) {
	file, err := os.Open("/proc/self/exe")
	if err != nil {
		return nil, "", err
	}
	return file, "/proc/" + strconv.Itoa(os.Getpid()) + "/fd/" + strconv.Itoa(int(file.Fd())), nil
}

// linuxTunnelHost is what the supervisor does to the machine; tests replace it.
type linuxTunnelHost struct {
	lock    func() (*os.File, error)
	reserve func() (linuxNetwork, error) // reaps dead supervisors' networks and records the new one
	cleanup func(linuxNetwork) error
	forget  func(linuxNetwork)
	worker  func(events func(linuxReply)) (*linuxChild, error)
}

func linuxSupervisor(ctx context.Context, input io.Reader, output io.Writer) int {
	uid := os.Getuid()
	if value := os.Getenv("PKEXEC_UID"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return 1
		}
		uid = parsed
	}
	commands, closed := linuxCommands(ctx, input)
	var stableMark atomic.Uint32
	var writer sync.Mutex
	send := func(reply linuxReply) error {
		writer.Lock()
		defer writer.Unlock()
		return linuxWriteFrame(output, reply)
	}
	self, executable, err := pinnedLinuxExecutable()
	if err != nil {
		return 1
	}
	defer self.Close()
	probeServer, err := startLinuxProbeServer(ctx, uid, executable, func() uint32 { return stableMark.Load() })
	if err != nil {
		return 1
	}
	defer probeServer()
	return superviseLinuxTunnels(ctx, commands, closed, send, uid, linuxTunnelHost{
		lock: func() (*os.File, error) { return acquireLinuxVPNLock(linuxVPNLock) },
		reserve: func() (linuxNetwork, error) {
			reapLinuxNetworks(linuxNetworkRecords, linuxNetwork.cleanup)
			network, err := reserveLinuxNetwork()
			if err != nil {
				return network, err
			}
			if stableMark.Load() == 0 {
				stableMark.Store(network.Mark)
			} else {
				network.Mark = stableMark.Load()
			}
			// Without a record only a reboot reaps the table if both processes are killed.
			// It is written with the mark the policy rules use, or reaping misses them.
			_ = network.record(linuxNetworkRecords)
			return network, nil
		},
		cleanup: linuxNetwork.cleanup,
		forget:  func(network linuxNetwork) { network.forget(linuxNetworkRecords) },
		worker: func(events func(linuxReply)) (*linuxChild, error) {
			return startLinuxChild(exec.Command(executable, "--linux-worker"), events)
		},
	})
}

// superviseLinuxTunnels runs one tunnel at a time for the broker. A tunnel that fails
// to start or ends by itself is reported and this root process waits for the next
// connect, which then needs no new consent. It exits on a stop it cannot clean up,
// on a protocol violation and when its owner goes.
func superviseLinuxTunnels(ctx context.Context, commands <-chan linuxCommand, closed <-chan struct{}, send func(linuxReply) error, owner int, host linuxTunnelHost) (code int) {
	var worker *linuxChild
	var network linuxNetwork
	var active *os.File
	// With Block traffic without VPN, only a requested stop removes the network. After
	// any other end it stays, with the tunnel lock, and blocks traffic until the next
	// tunnel replaces it or the next connect after this process exits reaps it.
	var block bool
	// held says the app's restart stop kept the network: unlike a lost tunnel's, a plain
	// stop then removes it, so a disconnect during a restart leaves nothing blocked.
	var held bool
	// release removes interception before the worker's DNS listener and tunnel, then the
	// rest. A failure keeps the network recorded for another attempt. A worker that had to
	// be killed leaves no state in this process.
	release := func() error {
		if worker != nil {
			if network.Name != "" {
				_ = host.cleanup(network)
			}
			_ = worker.stop()
			worker = nil
		}
		if network.Name == "" {
			return nil
		}
		if err := host.cleanup(network); err != nil {
			return err
		}
		host.forget(network)
		network = linuxNetwork{}
		return nil
	}
	// ended follows a tunnel that ended without a requested stop.
	ended := func() error {
		if !block || network.Name == "" {
			return release()
		}
		if worker != nil {
			_ = worker.stop()
			worker = nil
		}
		return nil
	}
	unlock := func() {
		if active != nil && network.Name == "" {
			active.Close()
			active = nil
		}
	}
	defer func() {
		if ended() != nil {
			code = 1
		}
		if active != nil {
			active.Close()
		}
	}()
	workerDone := func() <-chan struct{} {
		if worker == nil {
			return nil
		}
		return worker.done
	}
	for {
		select {
		case <-ctx.Done():
			return 0
		case <-closed:
			return 0
		case <-workerDone():
			// Its core stopped or it was killed. A cleanup failure exits, so the next
			// connect sees the leftover guard and offers to clear it.
			if ended() != nil {
				return 1
			}
			unlock()
			if send(linuxReply{Lost: true}) != nil {
				return 1
			}
		case command := <-commands:
			if command.Action == "stop" {
				// An idle stop keeps a lost tunnel's kill switch, like the Windows helper:
				// only the next tunnel, Repair or a reboot lifts it.
				switch {
				case worker != nil && command.Hold && block && network.Name != "":
					// The app starts another tunnel next: the kill switch covers the gap.
					_ = worker.stop()
					worker, held = nil, true
				case worker != nil || held && !command.Hold:
					block, held = false, false
					if release() != nil {
						return 1
					}
					unlock()
				}
				if send(linuxReply{Ready: true, PID: os.Getpid()}) != nil {
					return 1
				}
				continue
			}
			if worker != nil || validLinuxRequest(command.Request) != nil {
				_ = send(linuxReply{Error: "invalid_vpn_request"})
				return 1
			}
			// A kill switch kept from the last tunnel stays until this one has its own:
			// removed first, traffic left outside while the tunnel started. Its tunnel is
			// gone, so its table is empty and its rules route nothing; its guard rejects
			// this tunnel's traffic for the moment both exist.
			previous := network
			network, held = linuxNetwork{}, false
			reply := linuxReply{Error: "vpn_start_failed"}
			var err error
			if active == nil {
				active, err = host.lock()
			}
			if err != nil {
				reply.Error = err.Error()
			} else if network, err = host.reserve(); err != nil {
				network = linuxNetwork{}
				reply.Error = "vpn_resources_failed"
				if errors.Is(err, errLinuxFirewallUnavailable) {
					reply.Error = err.Error()
				}
			} else {
				command.Network = network
				block = command.Request.RoutePolicy != nil && command.Request.RoutePolicy.BlockWithoutVPN
				command.Owner = owner
				if worker, err = host.worker(func(reply linuxReply) { _ = send(reply) }); err != nil {
					worker = nil
					reply.Error = "vpn_worker_failed"
				} else {
					started := make(chan error, 1)
					go func(child *linuxChild, command linuxCommand) {
						_, err := child.request(command, 40*time.Second)
						started <- err
					}(worker, command)
					select {
					case <-ctx.Done():
						return 0
					case <-closed:
						return 0
					case err := <-started:
						if err == nil {
							reply = linuxReply{Ready: true, Adapter: network.Name, PID: os.Getpid()}
						}
					}
				}
			}
			// This long-lived root process's copy of the geodata is garbage now.
			command.assets = nil
			debug.FreeOSMemory()
			if previous.Name != "" {
				kept := !reply.Ready && command.Request.RoutePolicy != nil && command.Request.RoutePolicy.BlockWithoutVPN
				if kept {
					// What the failed start installed may be partial; the previous kill
					// switch is whole. Without the block setting nothing may stay blocked.
					block = false
					if release() != nil {
						return 1
					}
					network, block = previous, true
				} else if host.cleanup(previous) != nil {
					// Its guard would reject the new tunnel's traffic: the next connect
					// sees the leftover and offers to clear it.
					return 1
				} else {
					host.forget(previous)
				}
			}
			if !reply.Ready {
				if ended() != nil {
					return 1
				}
				unlock()
			}
			if send(reply) != nil {
				return 1
			}
		}
	}
}

func linuxWorker(ctx context.Context, input io.Reader, output io.Writer) (code int) {
	commands, closed := linuxCommands(ctx, input)
	var command linuxCommand
	select {
	case <-ctx.Done():
		return 1
	case <-closed:
		return 1
	case command = <-commands:
	}
	network := command.Network
	// Only the root supervisor can supply a resource identity.
	if command.Action != "start" || !network.valid() {
		return 1
	}
	// Under Block traffic without VPN only the supervisor removes the network, on a requested stop.
	block := command.Request.RoutePolicy != nil && command.Request.RoutePolicy.BlockWithoutVPN
	if command.Request.RecordDiagnostics && command.Owner >= 0 {
		defer startRecording(true, prepareLinuxRecording(command.Owner), command.Owner)()
		recordRuntimeConfig(command.Request.Config, command.Request.MemoryLimitMB, command.Request.TCPMaxConnections, command.Request.UDPMaxConnections, true)
	}
	defer func() {
		if !block && network.cleanup() != nil {
			code = 1
		}
		stopped := make(chan error, 1)
		go func() { stopped <- xray.StopXray() }()
		select {
		case err := <-stopped:
			if err != nil {
				code = 1
			}
		case <-time.After(2 * time.Second):
			code = 1
		}
	}()
	// The config is built for this network below, which checks it as well.
	if validLinuxLimits(command.Request) != nil || installAssets(command.assets) != nil {
		return 1
	}
	filesystem.NewFileReader = func(string) (io.ReadCloser, error) { return nil, errors.New("file_access_denied") }
	internet.RequiredSocketController = linuxMarkControl(network.Mark)
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, networkName, address string) (net.Conn, error) {
		return (&net.Dialer{Control: linuxMarkControl(network.Mark)}).DialContext(ctx, networkName, address)
	}}
	xnet.DefaultResolver = net.DefaultResolver
	config, err := linuxTunnelConfig([]byte(command.Request.Config), network, command.Request.RoutePolicy)
	if err != nil {
		return 1
	}
	tun.SetSessionLimits(command.Request.TCPMaxConnections, command.Request.UDPMaxConnections)
	limit := int64(math.MaxInt64)
	if command.Request.MemoryLimitMB > 0 {
		limit = int64(command.Request.MemoryLimitMB) * 1024 * 1024
	}
	xray.SetMemoryLimit(limit)
	logCursor := xray.LastLogSeq()
	started := make(chan error, 1)
	go func() { started <- xray.RunXrayFromJSON(string(config)) }()
	select {
	case <-ctx.Done():
		return 1
	case <-closed:
		return 1
	case err := <-started:
		if err != nil {
			return 1
		}
	case <-time.After(30 * time.Second):
		return 1
	}
	if err := network.install(command.Request.RoutePolicy); err != nil {
		return 1
	}
	// Marked sockets follow the kernel's physical route without re-binding, but pooled
	// connections must learn that it moved, or that the system slept, and verify themselves.
	wake := make(chan struct{}, 1)
	var resumed atomic.Bool
	notify := func() {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
	routes, unsubscribe := make(chan netlink.RouteUpdate, 16), make(chan struct{})
	defer close(unsubscribe)
	if netlink.RouteSubscribe(routes, unsubscribe) == nil {
		go func() {
			for range routes {
				notify()
			}
		}()
	}
	physical := func() [2]linuxRoute { return linuxPhysicalPath(network.Mark) }
	go watchSocketPath(wake, &resumed, physical(), time.Second, physical, internet.SocketPathChanged)
	sleep := newResumeClock(linuxSuspended)
	if linuxWriteFrame(output, linuxReply{Ready: true}) != nil {
		return 1
	}
	// A listed app's connections opened before the tunnel are not routed per app.
	go moveOpenedConnections(nil)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var gate metricsGate
	var connections connectionsCursor
	for {
		select {
		case <-ctx.Done():
			return 0
		case <-closed:
			return 0
		case <-commands:
			return 0
		case now := <-ticker.C:
			if !xray.GetXrayState() {
				return 1
			}
			if sleep.resumed() {
				resumed.Store(true)
				notify()
			}
			var reply linuxReply
			if logs := xray.ReadLogs(logCursor).Entries; len(logs) > 0 {
				logCursor = logs[len(logs)-1].Seq
				reply.Logs = logs
			}
			if command.Request.StreamMetrics {
				if metrics, err := xray.GetRuntimeMetrics(); err == nil && gate.due(metrics, reply.Logs != nil, now) {
					reply.Metrics = &metrics
				}
				reply.Connections = connections.read()
			}
			if (reply.Metrics != nil || reply.Logs != nil || reply.Connections != nil) && linuxWriteFrame(output, reply) != nil {
				return 1
			}
		}
	}
}

type linuxRoute struct {
	link            int
	gateway, source string
}

// linuxPhysicalPath is the route the kernel picks for marked sockets, per family. The
// lookup (ip route get ... mark) sends nothing; documentation addresses follow the default.
func linuxPhysicalPath(mark uint32) (path [2]linuxRoute) {
	for i, destination := range []string{"192.0.2.1", "2001:db8::1"} {
		if routes, err := netlink.RouteGetWithOptions(net.ParseIP(destination), &netlink.RouteGetOptions{Mark: mark}); err == nil && len(routes) > 0 {
			path[i] = linuxRoute{routes[0].LinkIndex, routes[0].Gw.String(), routes[0].Src.String()}
		}
	}
	return path
}

// linuxSuspended is the time this boot spent suspended: CLOCK_MONOTONIC stops then,
// CLOCK_BOOTTIME does not.
func linuxSuspended() time.Duration {
	var boot, monotonic unix.Timespec
	if unix.ClockGettime(unix.CLOCK_BOOTTIME, &boot) != nil || unix.ClockGettime(unix.CLOCK_MONOTONIC, &monotonic) != nil {
		return 0
	}
	return time.Duration(boot.Nano() - monotonic.Nano())
}
