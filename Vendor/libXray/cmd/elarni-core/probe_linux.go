//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"time"

	libxray "github.com/xtls/libxray"
	"github.com/xtls/libxray/geo"
	"github.com/xtls/libxray/share"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sync/semaphore"
	"golang.org/x/sys/unix"
)

type linuxProbeRequest struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload"`
	Mark    uint32          `json:"mark"`
	Sizes   map[string]int  `json:"assets"`
	assets  map[string][]byte
}
type linuxProbeReply struct {
	Data  json.RawMessage `json:"data"`
	Error string          `json:"error,omitempty"`
}

// The headless system service owns /run/elarni with mode 0700. Its
// private state must not block ordinary desktop users' physical probes.
var linuxProbeRoot = "/run/elarni-probes"

func linuxProbePath(uid int) string {
	return filepath.Join(linuxProbeRoot, strconv.Itoa(uid), "probe.sock")
}

// Root memory that same-user probe requests may pin with declared assets. Each
// request also holds a copy in its probe child.
const linuxProbeAssetBudget = 256 << 20

// Root probe cores that run at once; other admitted requests wait within their
// deadline. Each is a full core process with its own geodata copy, so 32 at once
// spiked RAM and CPU. 8 leaves room above the app's bulk test width plus a health check.
const linuxProbeRuns = 8

func readLinuxProbe(reader io.Reader) (linuxProbeRequest, error) {
	return readLinuxProbeAdmitted(reader, nil)
}

// admit reserves the declared asset bytes before any of them is read.
func readLinuxProbeAdmitted(reader io.Reader, admit func(int64) error) (linuxProbeRequest, error) {
	var request linuxProbeRequest
	if linuxReadFrame(reader, &request) != nil || (request.Method != "ping" && request.Method != "pingEndpoint") || len(request.Sizes) > 2 {
		return request, errors.New("invalid_request")
	}
	total := int64(0)
	for name, size := range request.Sizes {
		if (name != "geoip.dat" && name != "geosite.dat") || size <= 0 || size > geo.MaxFileBytes {
			return request, errors.New("invalid_assets")
		}
		total += int64(size)
	}
	if admit != nil && total > 0 {
		if err := admit(total); err != nil {
			return request, err
		}
	}
	request.assets = map[string][]byte{}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if size := request.Sizes[name]; size > 0 {
			// Grow with the bytes actually sent; a declared size alone must not reserve root memory.
			data, err := io.ReadAll(io.LimitReader(reader, int64(size)))
			if err != nil {
				return request, err
			}
			if len(data) != size {
				return request, io.ErrUnexpectedEOF
			}
			request.assets[name] = data
		}
	}
	return request, nil
}
func writeLinuxProbe(writer io.Writer, request linuxProbeRequest) error {
	request.Sizes = map[string]int{}
	for name, data := range request.assets {
		request.Sizes[name] = len(data)
	}
	if err := linuxWriteFrame(writer, request); err != nil {
		return err
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if data := request.assets[name]; len(data) > 0 {
			if _, err := io.Copy(writer, bytes.NewReader(data)); err != nil {
				return err
			}
		}
	}
	return nil
}
func callLinuxProbe(method string, payload json.RawMessage, assets map[string][]byte) (any, error, bool) {
	conn, err := net.DialTimeout("unix", linuxProbePath(os.Getuid()), time.Second)
	if err != nil {
		if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) {
			return nil, nil, false
		}
		return nil, errors.New("ping_failed"), true
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(22 * time.Second))
	if writeLinuxProbe(conn, linuxProbeRequest{Method: method, Payload: payload, assets: assets}) != nil {
		return nil, errors.New("ping_failed"), true
	}
	var reply linuxProbeReply
	if linuxReadFrame(conn, &reply) != nil {
		return nil, errors.New("ping_failed"), true
	}
	var data any
	if len(reply.Data) > 0 && json.Unmarshal(reply.Data, &data) != nil {
		return nil, errors.New("ping_failed"), true
	}
	if reply.Error != "" {
		return data, errors.New("ping_failed"), true
	}
	return data, nil, true
}
func linuxPhysicalProbe(payload json.RawMessage, assets map[string][]byte) (any, error, bool) {
	return callLinuxProbe("ping", payload, assets)
}
func linuxPingEndpoint(payload json.RawMessage) (any, error) {
	if data, err, handled := callLinuxProbe("pingEndpoint", payload, nil); handled {
		return data, err
	}
	return linuxTCPProbe(context.Background(), payload, 0)
}
func linuxTCPProbe(ctx context.Context, payload json.RawMessage, mark uint32) (any, error) {
	var request struct {
		Address string `json:"address"`
		Port    int    `json:"port"`
		Timeout int    `json:"timeout"`
	}
	if decodeLinuxJSON(payload, &request) != nil || request.Port < 1 || request.Port > 65535 || request.Timeout < 1 || request.Timeout > 15 {
		return nil, errors.New("invalid_request")
	}
	address, err := netip.ParseAddr(request.Address)
	if err != nil || address.IsUnspecified() || address.IsMulticast() {
		return nil, errors.New("invalid_request")
	}
	dialer := net.Dialer{Timeout: time.Duration(request.Timeout) * time.Second}
	if mark != 0 {
		dialer.Control = linuxMarkControl(mark)
	}
	started := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(address.String(), strconv.Itoa(request.Port)))
	if err != nil {
		return nil, errors.New("ping_failed")
	}
	conn.Close()
	return map[string]any{"delay": time.Since(started).Milliseconds()}, nil
}
func linuxICMP(payload json.RawMessage) (any, error) {
	var request struct {
		Address string `json:"address"`
		Timeout int    `json:"timeout"`
	}
	if decodeLinuxJSON(payload, &request) != nil || request.Timeout < 1 || request.Timeout > 15 {
		return nil, errors.New("invalid_request")
	}
	address, err := netip.ParseAddr(request.Address)
	if err != nil || address.IsUnspecified() || address.IsMulticast() {
		return nil, errors.New("invalid_request")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(request.Timeout+2)*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, linuxTool("ping", "/usr/bin", "/bin", "/run/wrappers/bin", "/run/current-system/sw/bin"), "-n", "-c", "1", "-W", strconv.Itoa(request.Timeout), "--", address.String())
	command.Env = []string{"LANG=C", "LC_ALL=C"}
	output, err := command.Output()
	if err != nil || len(output) > 8192 {
		return nil, errors.New("ping_failed")
	}
	match := regexp.MustCompile(`time[=<]([0-9]+(?:\.[0-9]+)?) ms`).FindSubmatch(output)
	if len(match) != 2 {
		return nil, errors.New("ping_failed")
	}
	delay, err := strconv.ParseFloat(string(match[1]), 64)
	if err != nil {
		return nil, errors.New("ping_failed")
	}
	return map[string]any{"milliseconds": int64(delay + 0.5)}, nil
}

func rootProbeDirectory(uid int) (string, error) {
	parent := filepath.Dir(filepath.Dir(linuxProbePath(uid)))
	directory := filepath.Dir(linuxProbePath(uid))
	for _, path := range []string{parent, directory} {
		if err := os.Mkdir(path, 0755); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
		info, err := os.Lstat(path)
		if err != nil || !info.IsDir() || info.Mode().Perm()&0022 != 0 {
			return "", errors.New("vpn_probe_failed")
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 {
			return "", errors.New("vpn_probe_failed")
		}
		// A root headless launcher uses umask 0077. The broker directories
		// must remain traversable; each socket and lock has its own 0600 ACL.
		if err := os.Chmod(path, 0755); err != nil {
			return "", err
		}
	}
	return directory, nil
}
func startLinuxProbeServer(parent context.Context, uid int, executable string, mark func() uint32) (func(), error) {
	directory, err := rootProbeDirectory(uid)
	if err != nil {
		return nil, err
	}
	fd, err := unix.Open(filepath.Join(directory, "owner.lock"), unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	lock := os.NewFile(uintptr(fd), "owner.lock")
	if unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB) != nil {
		lock.Close()
		return nil, errors.New("vpn_resources_busy")
	}
	path := linuxProbePath(uid)
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			lock.Close()
			return nil, errors.New("vpn_probe_failed")
		}
		if err := os.Remove(path); err != nil {
			lock.Close()
			return nil, err
		}
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		lock.Close()
		return nil, err
	}
	if os.Chown(path, uid, -1) != nil || os.Chmod(path, 0600) != nil {
		listener.Close()
		lock.Close()
		return nil, errors.New("vpn_probe_failed")
	}
	ctx, cancel := context.WithCancel(parent)
	var workers sync.WaitGroup
	// Match the shared desktop's bounded bulk-ping concurrency.
	slots := make(chan struct{}, 32)
	runs := semaphore.NewWeighted(linuxProbeRuns)
	assetBudget := semaphore.NewWeighted(linuxProbeAssetBudget)
	workers.Add(1)
	go func() {
		defer workers.Done()
		for {
			conn, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			raw, err := conn.SyscallConn()
			var peer *unix.Ucred
			if err == nil {
				err = raw.Control(func(fd uintptr) { peer, _ = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED) })
			}
			if err != nil || peer == nil || int(peer.Uid) != uid {
				conn.Close()
				continue
			}
			select {
			case slots <- struct{}{}:
			default:
				conn.Close()
				continue
			}
			workers.Add(1)
			go func() {
				defer workers.Done()
				stopClose := context.AfterFunc(ctx, func() { conn.Close() })
				defer stopClose()
				defer func() { <-slots }()
				defer conn.Close()
				deadline := time.Now().Add(25 * time.Second)
				_ = conn.SetDeadline(deadline)
				var reserved int64
				defer func() {
					if reserved > 0 {
						assetBudget.Release(reserved)
					}
				}()
				request, err := readLinuxProbeAdmitted(conn, func(size int64) error {
					admission, cancel := context.WithDeadline(ctx, deadline)
					defer cancel()
					if err := assetBudget.Acquire(admission, size); err != nil {
						return err
					}
					reserved = size
					return nil
				})
				if err != nil {
					return
				}
				admission, cancel := context.WithDeadline(ctx, deadline)
				err = runs.Acquire(admission, 1)
				cancel()
				if err != nil {
					return
				}
				defer runs.Release(1)
				request.Mark = mark()
				childCtx, childCancel := context.WithTimeout(ctx, 20*time.Second)
				defer childCancel()
				command := exec.CommandContext(childCtx, executable, "--linux-probe")
				input, err := command.StdinPipe()
				if err != nil {
					return
				}
				output, err := command.StdoutPipe()
				if err != nil {
					input.Close()
					return
				}
				command.Stderr = io.Discard
				if command.Start() != nil {
					input.Close()
					output.Close()
					return
				}
				go func() { var byte [1]byte; _, _ = conn.Read(byte[:]); childCancel() }()
				if writeLinuxProbe(input, request) != nil {
					childCancel()
				}
				var reply linuxProbeReply
				if linuxReadFrame(output, &reply) == nil {
					_ = linuxWriteFrame(conn, reply)
				}
				input.Close()
				output.Close()
				childCancel()
				_ = command.Wait()
			}()
		}
	}()
	return func() { cancel(); listener.Close(); workers.Wait(); _ = os.Remove(path); lock.Close() }, nil
}

func linuxProbeConfig(raw string) (string, error) {
	if len(raw) > 8*1024*1024 {
		return "", errors.New("invalid_configuration")
	}
	var config map[string]any
	if json.Unmarshal([]byte(raw), &config) != nil {
		return "", errors.New("invalid_configuration")
	}
	inbounds, ok := config["inbounds"].([]any)
	if !ok || len(inbounds) < 1 || len(inbounds) > 2 {
		return "", errors.New("invalid_configuration")
	}
	hasSOCKS := false
	for _, entry := range inbounds {
		inbound, ok := entry.(map[string]any)
		if !ok || inbound["listen"] != "127.0.0.1" || (inbound["protocol"] != "socks" && inbound["protocol"] != "http") {
			return "", errors.New("invalid_configuration")
		}
		hasSOCKS = hasSOCKS || inbound["protocol"] == "socks"
	}
	// The shared VPN validator requires SOCKS. Supply a validation-only inlet
	// for an HTTP-only probe and remove it before starting the probe runtime.
	if !hasSOCKS {
		port := 1
		if inbounds[0].(map[string]any)["port"] == float64(port) {
			port++
		}
		inbounds = append(inbounds, map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": port})
	}
	config["inbounds"] = append(inbounds, map[string]any{"protocol": "tun", "tag": "elarni-tun", "port": 0, "settings": map[string]any{}})
	source, _ := json.Marshal(config)
	validated, err := share.WindowsTunnelConfig(source, "rvprobe")
	if err != nil {
		return "", err
	}
	if json.Unmarshal(validated, &config) != nil {
		return "", errors.New("invalid_configuration")
	}
	owned := config["inbounds"].([]any)
	kept := []any{}
	for _, entry := range owned[1:] {
		if hasSOCKS || entry.(map[string]any)["protocol"] != "socks" {
			kept = append(kept, entry)
		}
	}
	config["inbounds"] = kept
	// No TUN or global DNS interception exists in a probe process.
	outbounds := config["outbounds"].([]any)
	config["outbounds"] = outbounds[:len(outbounds)-1]
	routing := config["routing"].(map[string]any)
	rules := routing["rules"].([]any)
	routing["rules"] = rules[1:]
	result, err := json.Marshal(config)
	return string(result), err
}
func linuxProbeChild(ctx context.Context, input io.Reader, output io.Writer) int {
	request, err := readLinuxProbe(input)
	if err != nil {
		return 1
	}
	var data any
	if request.Method == "pingEndpoint" {
		data, err = linuxTCPProbe(ctx, request.Payload, request.Mark)
	} else {
		var payload struct {
			libxray.PingRequest
			AssetRevision string `json:"assetRevision"`
		}
		if decodeLinuxJSON(request.Payload, &payload) != nil || payload.PacketPath || payload.OperationID != "" {
			return 1
		}
		payload.ConfigJSON, err = linuxProbeConfig(payload.ConfigJSON)
		if err != nil {
			return 1
		}
		if installAssets(request.assets) != nil {
			return 1
		}
		filesystem.NewFileReader = func(string) (io.ReadCloser, error) { return nil, errors.New("file_access_denied") }
		internet.RequiredSocketController = linuxMarkControl(request.Mark)
		net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{Control: linuxMarkControl(request.Mark)}).DialContext(ctx, network, address)
		}}
		xnet.DefaultResolver = net.DefaultResolver
		encoded, _ := json.Marshal(map[string]any{"apiVersion": 1, "method": "ping", "payload": payload.PingRequest})
		var response struct {
			Success bool
			Data    *libxray.PingResponse
		}
		if json.Unmarshal([]byte(libxray.Invoke(string(encoded))), &response) != nil {
			return 1
		}
		data = response.Data
		if !response.Success {
			err = errors.New("ping_failed")
		}
	}
	encoded, _ := json.Marshal(data)
	reply := linuxProbeReply{Data: encoded}
	if err != nil {
		reply.Error = "ping_failed"
	}
	if linuxWriteFrame(output, reply) != nil {
		return 1
	}
	return 0
}
