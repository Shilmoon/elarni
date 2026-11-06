// elarni-core owns one import or one running local proxy. Closing the parent
// input pipe ends the process, including when the parent dies during startup.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	libxray "github.com/xtls/libxray"
	"github.com/xtls/libxray/xray"
)

const maxMessage = 16 * 1024 * 1024

type response struct {
	text    string
	run     bool
	hold    bool // A storage lease lives until the parent's pipe closes.
	session bool // Windows may reuse its elevated owner until parent EOF.
}

func dispatch(raw string) (result response) {
	result.text = `{"success":false,"error":"invalid_request"}`
	defer func() {
		if recover() != nil {
			result = response{text: `{"success":false,"error":"core_failed"}`}
		}
	}()
	var request libxray.LibXrayInvokeRequest
	if len(raw) > maxMessage || json.Unmarshal([]byte(raw), &request) != nil || request.APIVersion != 1 {
		return
	}
	diagnosticsRequest(string(request.Method), request.Payload)
	if request.Method == "diagnostics" {
		data, err := recordingRequest(request.Payload)
		result.text = nativeResponse(data, err)
		return
	}
	if data, err, handled := platformRequest(string(request.Method), request.Payload); handled {
		result.text = nativeResponse(data, err)
		result.hold = string(request.Method) == "acquireCatalog" && err == nil
		result.run = string(request.Method) == "runVPN" && err == nil
		var options struct {
			ReuseSession bool `json:"reuseSession"`
		}
		_ = json.Unmarshal(request.Payload, &options)
		result.session = result.run && options.ReuseSession
		return
	}
	if data, err, handled := dataRequest(string(request.Method), request.Payload); handled {
		result.text = nativeResponse(data, err)
		return
	}
	var code string
	switch request.Method {
	case libxray.LibXrayMethodImportClientProfiles, libxray.LibXrayMethodNormalizeClientInput:
		code = "unsupported_profile"
	case libxray.LibXrayMethodProfileHostMappings:
		code = "invalid_profile"
	case libxray.LibXrayMethodClientQR:
		code = "sharing_failed"
	case "validateSubscriptionFetchOptions":
		code = "invalid_settings"
	case "subscriptionDeviceID":
		code = "invalid_target"
	case "sealCatalogBackup", "openCatalogBackup", "validateCatalogBackup":
		code = "invalid_backup"
	case libxray.LibXrayMethodRunXrayFromJson:
		code = "connection_failed"
		var limits struct {
			MemoryLimitMB int    `json:"memoryLimitMB"`
			LogLevel      string `json:"logLevel"`
		}
		if json.Unmarshal(request.Payload, &limits) != nil || limits.MemoryLimitMB < 0 || limits.MemoryLimitMB > 4096 ||
			limits.LogLevel != "" && xray.SetLogLevel(limits.LogLevel) != nil {
			return
		}
		if limits.MemoryLimitMB > 0 {
			xray.SetMemoryLimit(int64(limits.MemoryLimitMB) * 1024 * 1024)
		}
	case libxray.LibXrayMethodPing:
		code = "ping_failed"
	default:
		return
	}
	result.text = libxray.Invoke(raw)
	var reply struct {
		Success bool `json:"success"`
	}
	if json.Unmarshal([]byte(result.text), &reply) != nil || !reply.Success {
		if request.Method == libxray.LibXrayMethodPing {
			// Probe diagnostics contain typed codes and stages, never endpoints.
			var parsed struct {
				Data *libxray.PingResponse `json:"data"`
			}
			if json.Unmarshal([]byte(result.text), &parsed) == nil && parsed.Data != nil {
				encoded, _ := json.Marshal(map[string]any{"success": false, "error": code, "data": parsed.Data})
				result.text = string(encoded)
				return
			}
		}
		result.text = fmt.Sprintf(`{"success":false,"error":%q}`, code)
		return
	}
	result.run = request.Method == libxray.LibXrayMethodRunXrayFromJson
	if result.run && !xray.GetXrayState() {
		return response{text: `{"success":false,"error":"connection_failed"}`}
	}
	return
}

func nativeResponse(data any, err error) string {
	if err != nil {
		// Native operations return fixed error codes, never OS/path diagnostics.
		response := map[string]any{"success": false, "error": err.Error()}
		if data != nil {
			response["data"] = data
		}
		encoded, _ := json.Marshal(response)
		return string(encoded)
	}
	encoded, err := json.Marshal(map[string]any{"success": true, "data": data})
	if err != nil || len(encoded) > maxMessage {
		return `{"success":false,"error":"response_too_large"}`
	}
	return string(encoded)
}

func serve(input io.Reader, output io.Writer, invoke func(string) response, stop func() error, running func() bool) int {
	logCursor := xray.LastLogSeq()
	// EOF detection cannot wait for Invoke: startup can hold the core mutex.
	requests := make(chan string, 1)
	closed := make(chan struct{})
	go func() {
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 64*1024), maxMessage+1)
		if scanner.Scan() {
			raw := scanner.Text()
			requests <- raw
			var request struct {
				Method  string `json:"method"`
				Payload struct {
					ReuseSession bool `json:"reuseSession"`
				} `json:"payload"`
			}
			_ = json.Unmarshal([]byte(raw), &request)
			if request.Method == "runVPN" && request.Payload.ReuseSession || request.Method == "acquireCatalog" {
				for scanner.Scan() {
					select {
					case requests <- scanner.Text():
					default: // Only one outstanding session or lease command is allowed.
						close(closed)
						return
					}
				}
			} else {
				scanner.Scan() // A second one-shot command is a protocol violation.
			}
		}
		close(closed)
	}()
	defer func() {
		done := make(chan struct{})
		go func() { _ = stop(); close(done) }()
		select {
		case <-done:
		case <-time.After(8 * time.Second):
			// Returning from main also ends a stuck startup/shutdown goroutine.
		}
	}()
	var raw string
	select {
	case raw = <-requests:
	case <-closed:
		return 0
	}
	results := make(chan response, 1)
	go func() { results <- invoke(raw) }()
	var result response
	select {
	case result = <-results:
	case <-closed:
		return 0
	}
	written := make(chan error, 1)
	go func() { _, err := fmt.Fprintln(output, result.text); written <- err }()
	select {
	case err := <-written:
		if err != nil {
			return 1
		}
	case <-closed:
		return 0
	}
	var options struct {
		Payload struct {
			StreamMetrics bool `json:"streamMetrics"`
		} `json:"payload"`
	}
	_ = json.Unmarshal([]byte(raw), &options)
	if result.session {
		return serveVPNSession(requests, closed, output, invoke, running, options.Payload.StreamMetrics, logCursor)
	}
	if result.hold {
		return serveCatalogLease(requests, closed, output, invoke)
	}
	if !result.run {
		return 0
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var gate metricsGate
	for {
		select {
		case <-closed:
			return 0
		case now := <-ticker.C:
			if result.run && !running() {
				return 1
			}
			var events []any
			logs := logEvent(&logCursor)
			if result.run && options.Payload.StreamMetrics {
				metrics, err := platformMetrics()
				if err != nil {
					metrics, err = xray.GetRuntimeMetrics()
				}
				if err == nil && gate.due(metrics, logs != nil, now) {
					events = append(events, map[string]any{"event": "metrics", "data": metrics})
				}
			}
			if logs != nil {
				events = append(events, logs)
			}
			for _, event := range events {
				go func() { written <- json.NewEncoder(output).Encode(event) }()
				select {
				case err := <-written:
					if err != nil {
						return 1
					}
				case <-closed:
					return 0
				}
			}
		}
	}
}

// A session only accepts tunnel start/stop operations. All other native methods
// keep their one-shot lifetime, including probes with independent Xray globals.
func serveVPNSession(requests <-chan string, closed <-chan struct{}, output io.Writer, invoke func(string) response, running func() bool, streamMetrics bool, logCursor int64) int {
	active := true
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var gate metricsGate
	write := func(value any) bool {
		done := make(chan error, 1)
		go func() { done <- json.NewEncoder(output).Encode(value) }()
		select {
		case err := <-done:
			return err == nil
		case <-closed:
			return false
		}
	}
	for {
		select {
		case <-closed:
			return 0
		case raw := <-requests:
			var request struct {
				APIVersion int    `json:"apiVersion"`
				Method     string `json:"method"`
				Payload    struct {
					StreamMetrics bool `json:"streamMetrics"`
				} `json:"payload"`
			}
			if json.Unmarshal([]byte(raw), &request) != nil || request.APIVersion != 1 ||
				(request.Method != "runVPN" && request.Method != "stopVPN") || request.Method == "runVPN" && active {
				return 1
			}
			done := make(chan response, 1)
			go func() { done <- invoke(raw) }()
			select {
			case result := <-done:
				if !write(json.RawMessage(result.text)) {
					select {
					case <-closed:
						return 0
					default:
						return 1
					}
				}
				var reply struct {
					Success bool `json:"success"`
				}
				if json.Unmarshal([]byte(result.text), &reply) != nil || !reply.Success {
					return 1
				}
				active = result.run
				streamMetrics = request.Payload.StreamMetrics
				gate = metricsGate{} // a new tunnel reports at once
			case <-closed:
				return 0
			}
		case now := <-ticker.C:
			if !running() {
				return 1
			}
			logs := logEvent(&logCursor)
			if active && streamMetrics {
				if metrics, err := platformMetrics(); err == nil && gate.due(metrics, logs != nil, now) &&
					!write(map[string]any{"event": "metrics", "data": metrics}) {
					return 1
				}
			}
			if active && logs != nil && !write(logs) {
				return 1
			}
		}
	}
}

// metricsHeartbeat is how long an unchanged metrics frame is held back. The desktop app counts metrics older
// than 25 s as unavailable (runtimeMetrics in lib/desktop_proxy_commands.dart), so that bound must stay above
// two heartbeats: the worker's gate and the session's gate each add up to one.
const metricsHeartbeat = 10 * time.Second

// metricsGate passes a frame when traffic or sessions changed, logs came, or a heartbeat passed. An idle tunnel then
// wakes the supervisor, the session and the app every 10 s instead of every second; heap sizes ride along.
type metricsGate struct {
	last xray.RuntimeMetrics
	at   time.Time
	sent bool
}

func (gate *metricsGate) due(metrics xray.RuntimeMetrics, logs bool, now time.Time) bool {
	metrics.HeapAllocBytes, metrics.HeapSysBytes = 0, 0
	if gate.sent && !logs && metrics == gate.last && now.Sub(gate.at) < metricsHeartbeat {
		return false
	}
	gate.last, gate.at, gate.sent = metrics, now, true
	return true
}

// logEvent carries the lines recorded after the cursor and moves it past them.
func logEvent(cursor *int64) any {
	logs := xray.ReadLogs(*cursor)
	if len(logs.Entries) == 0 {
		return nil
	}
	*cursor = logs.Entries[len(logs.Entries)-1].Seq
	return map[string]any{"event": "logs", "data": logs}
}

// The storage lease also serves its owner's catalog reads and writes, one at a
// time, so they need no core launch each. They keep the same lock, revision
// check and atomic replacement. It also answers the unelevated DNS guard check
// before each Windows connect. Any other command ends the lease.
func serveCatalogLease(requests <-chan string, closed <-chan struct{}, output io.Writer, invoke func(string) response) int {
	for {
		select {
		case <-closed:
			return 0
		case raw := <-requests:
			var request struct {
				APIVersion int    `json:"apiVersion"`
				Method     string `json:"method"`
			}
			if json.Unmarshal([]byte(raw), &request) != nil || request.APIVersion != 1 ||
				request.Method != "loadCatalog" && request.Method != "saveCatalog" && request.Method != "staleVPNGuard" {
				return 1
			}
			done := make(chan response, 1)
			go func() { done <- invoke(raw) }()
			var result response
			select {
			case result = <-done:
			case <-closed:
				return 0
			}
			written := make(chan error, 1)
			go func() { _, err := fmt.Fprintln(output, result.text); written <- err }()
			select {
			case err := <-written:
				if err != nil {
					return 1
				}
			case <-closed:
				return 0
			}
		}
	}
}

func main() {
	if handled, code := diagnosticsMain(); handled {
		os.Exit(code)
	}
	if handled, code := platformMain(); handled {
		diagnosticsFlush()
		os.Exit(code)
	}
	protocol := os.Stdout
	os.Stdout = os.Stderr // Reserve the original stdout for protocol responses.
	code := serve(os.Stdin, protocol, dispatch, func() error { platformStop(); return xray.StopXray() },
		func() bool { return platformRunning() || xray.GetXrayState() })
	diagnosticsFlush()
	os.Exit(code)
}
