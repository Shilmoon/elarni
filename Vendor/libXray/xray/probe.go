package xray

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/libxray/nodep"
	"github.com/xtls/libxray/share"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/core"
)

// Configuration construction consumes process-wide environment/asset readers.
// Running cores use their own DNS/outbound features, so only startup is serial.
var probeStartup sync.Mutex
var probeQuarantine atomic.Int32

type ProbeDiagnostics struct {
	ProbeID             uint64        `json:"probeId"`
	Events              []probe.Event `json:"events"`
	Code                string        `json:"code"`
	Stage               string        `json:"stage"`
	TransportCode       string        `json:"transportCode"`
	CleanupState        string        `json:"cleanupState"`
	CleanupCode         string        `json:"cleanupCode,omitempty"`
	HTTPStatus          int           `json:"httpStatus,omitempty"`
	TrackedWorkComplete bool          `json:"trackedWorkComplete"`
}

// PingJSONWithPreparation returns only typed, endpoint-free diagnostic fields.
// The HTTP timeout still measures the original request; cleanup retains ownership.
// prepare installs platform assets until configuration construction completes.
func PingJSONWithPreparation(parent context.Context, configJSON string, timeout int, targetURL, proxyURL, method, mode, variant string, prepare func() (func(), error), expected ...*nodep.ExpectedResponse) (delay int64, diagnostic *ProbeDiagnostics, err error) {
	diagnostic = &ProbeDiagnostics{CleanupState: "not_started", Stage: "admission"}
	delay = nodep.PingDelayError
	if err = share.ValidateClientFileAccess([]byte(configJSON)); err != nil {
		diagnostic.Code = "invalid_configuration"
		diagnostic.TransportCode = diagnostic.Code
		return
	}
	target, parseErr := url.Parse(targetURL)
	if parseErr != nil || target.Hostname() == "" {
		diagnostic.Code = "invalid_target"
		diagnostic.TransportCode = diagnostic.Code
		return delay, diagnostic, errors.New("invalid_target")
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(timeout)*time.Second)
	ctx, recorder := probe.New(ctx, target.Hostname())
	defer cancel()
	defer func() {
		probe.Emit(ctx, "native_return", err, 0)
		diagnostic.ProbeID, diagnostic.Events = recorder.Snapshot()
		diagnostic.Code = probe.Code(err)
		if err != nil && err.Error() == "probe_busy" {
			diagnostic.Code = "probe_busy"
		}
		diagnostic.TransportCode = diagnostic.Code
		for _, event := range diagnostic.Events {
			if event.Stage == "target_response" {
				diagnostic.HTTPStatus = event.Status
			}
			if err != nil && event.Stage == "target_dns_done" && event.Code != "ok" {
				diagnostic.Code = "target_dns_failed"
				diagnostic.Stage = "target_dns"
			}
		}
	}()
	probe.Emit(ctx, "native_enter", nil, 0)
	if err = ctx.Err(); err != nil {
		return
	}
	probeStartup.Lock()
	starting := true
	defer func() {
		if starting {
			probeStartup.Unlock()
		}
	}()
	if probeQuarantine.Load() > 0 {
		return delay, diagnostic, errors.New("probe_busy")
	}
	if err = ctx.Err(); err != nil {
		return
	}
	var restore func()
	if prepare != nil {
		restore, err = prepare()
		if err != nil {
			return
		}
	}
	defer func() {
		if restore != nil {
			restore()
		}
	}()
	probe.Emit(ctx, "instance_admitted", nil, 0)
	configJSON, err = probeControl(ctx, configJSON, targetURL, method, mode, variant)
	if err != nil {
		return
	}
	diagnostic.Stage = "instance_start"
	probe.Emit(ctx, "instance_start_begin", nil, 0)
	config, err := core.LoadConfig("json", strings.NewReader(configJSON))
	if err != nil {
		return delay, diagnostic, err
	}
	if err = ctx.Err(); err != nil {
		return
	}
	server, err := core.NewWithContext(ctx, config)
	if err != nil {
		return delay, diagnostic, err
	}
	defer func() {
		cancel()
		probe.Emit(ctx, "instance_close_begin", nil, 0)
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 2*time.Second)
		complete, closed, pending := awaitProbeCleanup(cleanupCtx, server.Close, recorder.CloseTransport)
		cleanupCancel()
		diagnostic.TrackedWorkComplete = complete && closed.tracked
		probe.Emit(ctx, "instance_close_end", closed.err, 0)
		diagnostic.CleanupCode = probe.Code(closed.err)
		// Core Close does not prove every detached transport goroutine has exited.
		diagnostic.CleanupState = "instance_closed"
		if complete && (closed.err != nil || !closed.tracked) {
			diagnostic.CleanupState = "failed"
			if err == nil {
				err = errors.New("probe_cleanup_failed")
			}
		}
		holdProbesUntilCleanup(complete, pending)
		if !complete {
			diagnostic.CleanupState = "pending"
			if err == nil {
				err = errors.New("probe_cleanup_pending")
			}
		}
	}()
	if err = ctx.Err(); err != nil {
		return
	}
	err = server.Start()
	probe.Emit(ctx, "instance_start_end", err, 0)
	if err != nil {
		return
	}
	if restore != nil {
		restore()
		restore = nil
	}
	starting = false
	probeStartup.Unlock()
	diagnostic.Stage = "target_request"
	probe.Emit(ctx, "request_begin", nil, 0)
	delay, err = nodep.MeasureDelayContext(ctx, timeout, targetURL, proxyURL, method, mode, expected...)
	probe.Emit(ctx, "request_end", err, 0)
	return
}

// holdProbesUntilCleanup admits no new probe while a returned probe's cleanup
// still runs. A finished cleanup releases the hold whatever its error: nothing
// clears a failed close later, so keeping the hold would refuse every probe.
func holdProbesUntilCleanup(complete bool, pending <-chan probeCleanupResult) {
	if complete {
		return
	}
	probeQuarantine.Add(1)
	go func() {
		<-pending
		probeQuarantine.Add(-1)
	}()
}

type probeCleanupResult struct {
	err     error
	tracked bool
}

func awaitProbeCleanup(ctx context.Context, closeInstance func() error, join func(context.Context) bool) (bool, probeCleanupResult, <-chan probeCleanupResult) {
	done := make(chan probeCleanupResult, 1)
	go func() {
		err := closeInstance()
		done <- probeCleanupResult{err: err, tracked: join(context.Background())}
	}()
	select {
	case result := <-done:
		return true, result, done
	case <-ctx.Done():
		return false, probeCleanupResult{err: ctx.Err()}, done
	}
}

// Controls modify only a disposable compiled config, never saved settings.
func probeControl(ctx context.Context, configJSON, targetURL, method, mode, variant string) (string, error) {
	if variant == "" || variant == "baseline" {
		return configJSON, nil
	}
	if targetURL != "https://www.gstatic.com/generate_204" || method != "GET" || mode != "default" {
		return "", errors.New("invalid_diagnostic_control")
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
		return "", err
	}
	switch variant {
	case "target_hosts":
		lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		addresses, err := net.DefaultResolver.LookupIP(lookupCtx, "ip4", "www.gstatic.com")
		probe.Emit(ctx, "control_system_resolution", err, 0)
		if err != nil {
			return "", err
		}
		if len(addresses) == 0 {
			return "", errors.New("control_no_ipv4")
		}
		dns, ok := config["dns"].(map[string]any)
		if !ok {
			return "", errors.New("control_missing_dns")
		}
		hosts, _ := dns["hosts"].(map[string]any)
		if hosts == nil {
			hosts = map[string]any{}
			dns["hosts"] = hosts
		}
		hosts["full:www.gstatic.com"] = addresses[0].String()
	case "as_is":
		outbounds, _ := config["outbounds"].([]any)
		found := false
		for _, value := range outbounds {
			outbound, _ := value.(map[string]any)
			if outbound["tag"] == "elarni-proxy" {
				outbound["targetStrategy"] = "AsIs"
				found = true
			}
		}
		if !found {
			return "", errors.New("control_missing_outbound")
		}
	case "tcp_dns":
		dns, ok := config["dns"].(map[string]any)
		if !ok {
			return "", errors.New("control_missing_dns")
		}
		dns["servers"] = []string{"tcp://1.1.1.1:53"}
	default:
		return "", errors.New("invalid_diagnostic_control")
	}
	data, err := json.Marshal(config)
	return string(data), err
}
