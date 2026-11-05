package libXray

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/xtls/libxray/geo"
	"github.com/xtls/libxray/nodep"
	"github.com/xtls/libxray/share"
	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/transport/internet"
)

type invokeResponse struct {
	Success bool   `json:"success"`
	Data    any    `json:"data"`
	Err     string `json:"error"`
}

const (
	maxInvokeJSONSizeMiB = 16
	maxInvokeJSONBytes   = maxInvokeJSONSizeMiB * 1024 * 1024
)

func Invoke(requestJSON string) string {
	if len(requestJSON) > maxInvokeJSONBytes {
		return encodeInvokeResponse(nil, errors.New(invokeJSONSizeLimitMessage("request")))
	}
	var request LibXrayInvokeRequest
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return encodeInvokeResponse(nil, err)
	}
	if err := validateAPIVersion(request.APIVersion); err != nil {
		return encodeInvokeResponse(nil, err)
	}

	switch request.Method {
	case "diagnostics":
		result, err := flightrecorder.Command(request.Payload)
		if errors.Is(err, flightrecorder.ErrEmpty) {
			err = errors.New("recording_empty") // the apps tell the user to record first
		}
		return encodeInvokeResponse(result, err)
	case LibXrayMethodGetFreePorts:
		return invokeGetFreePorts(request.Payload)
	case LibXrayMethodConvertShareLinksToXrayJson:
		return invokeConvertShareLinksToXrayJson(request.Payload)
	case LibXrayMethodImportClientProfiles:
		payload, err := decodePayload[ClientImportRequest](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid client import payload"))
		}
		result, err := share.ImportClientProfiles(payload.Text)
		if err == nil && payload.SourceURL != "" {
			// An invalid move hint is ignored so the parsed servers still apply.
			if newURL, hintErr := share.SubscriptionMigrationURL(payload.SourceURL, result.Migration, payload.MigrationHeaders); hintErr == nil {
				result.NewSourceURL = newURL
			}
			result.FallbackURL = share.SubscriptionFallbackURL(payload.SourceURL, result.Migration, payload.MigrationHeaders)
		}
		return encodeInvokeResponse(result, err)
	case LibXrayMethodNormalizeClientInput:
		payload, err := decodePayload[ConvertShareLinksToXrayJsonRequest](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid client import payload"))
		}
		result, err := share.NormalizeClientInput(payload.Text)
		return encodeInvokeResponse(result, err)
	case LibXrayMethodClientQR:
		payload, err := decodePayload[ConvertShareLinksToXrayJsonRequest](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid sharing payload"))
		}
		result, err := share.ClientQR(payload.Text)
		return encodeInvokeResponse(result, err)
	case LibXrayMethodProfileHostMappings:
		payload, err := decodePayload[struct {
			ConfigJSON string   `json:"configJSON"`
			Hosts      []string `json:"hosts"`
		}](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid profile hosts payload"))
		}
		result, err := share.ProfileHostMappings(payload.ConfigJSON, payload.Hosts)
		return encodeInvokeResponse(result, err)
	case LibXrayMethodConvertXrayJsonToShareLinks:
		return invokeConvertXrayJsonToShareLinks(request.Payload)
	case LibXrayMethodCountGeoData:
		return invokeCountGeoData(request.Payload)
	case LibXrayMethodPing:
		return invokePing(request.Payload)
	case LibXrayMethodPrepareProbe, LibXrayMethodCancelProbe, LibXrayMethodReleaseProbe:
		return invokeProbeOperation(request.Method, request.Payload)
	case LibXrayMethodFetchSubscription, LibXrayMethodFetchResource, LibXrayMethodPrepareFetch, LibXrayMethodCancelFetch, LibXrayMethodReleaseFetch:
		return invokeFetch(request.Method, request.Payload)
	case "validateSubscriptionFetchOptions":
		payload, err := decodePayload[share.SubscriptionFetchRequest](request.Payload)
		if err == nil {
			err = payload.ValidateOptions()
		}
		return encodeInvokeResponse(map[string]bool{"valid": err == nil}, err)
	case "subscriptionDeviceID":
		payload, err := decodePayload[share.SubscriptionFetchRequest](request.Payload)
		id := ""
		if err == nil {
			id, err = share.SubscriptionDeviceID(payload)
		}
		return encodeInvokeResponse(map[string]string{"deviceId": id}, err)
	case "sealCatalogBackup", "openCatalogBackup":
		payload, err := decodePayload[struct {
			Catalog  json.RawMessage `json:"catalog"`
			Text     string          `json:"text"`
			Password string          `json:"password"`
		}](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid_backup"))
		}
		if request.Method == "sealCatalogBackup" {
			text, err := share.SealCatalogBackup(payload.Catalog, payload.Password)
			return encodeInvokeResponse(map[string]string{"text": text}, err)
		}
		catalog, err := share.OpenCatalogBackup(payload.Text, payload.Password)
		return encodeInvokeResponse(map[string]any{"catalog": catalog}, err)
	case "validateCatalogBackup":
		payload, err := decodePayload[struct {
			Catalog json.RawMessage `json:"catalog"`
		}](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, errors.New("invalid_backup"))
		}
		catalog, err := share.ValidateCatalogBackup(payload.Catalog)
		return encodeInvokeResponse(map[string]any{"catalog": catalog}, err)
	case LibXrayMethodPingBatch:
		return invokePingBatch(request.Payload)
	case LibXrayMethodTestXray:
		return invokeTestXray(request.Payload)
	case LibXrayMethodRunXray:
		return invokeRunXray(request.Payload)
	case LibXrayMethodRunXrayFromJson:
		return invokeRunXrayFromJSON(request.Payload)
	case LibXrayMethodStopXray:
		return encodeInvokeNoDataResponse(xray.StopXray())
	case LibXrayMethodXrayVersion:
		return encodeInvokeResponse(&XrayVersionResponse{Version: xray.XrayVersion()}, nil)
	case LibXrayMethodGetXrayState:
		return encodeInvokeResponse(&GetXrayStateResponse{Running: xray.GetXrayState()}, nil)
	case LibXrayMethodSetMemoryLimit:
		return invokeSetMemoryLimit(request.Payload)
	case LibXrayMethodGetRuntimeMetrics:
		metrics, err := xray.GetRuntimeMetrics()
		return encodeInvokeResponse(&metrics, err)
	case LibXrayMethodSetLogLevel:
		request, err := decodePayload[SetLogLevelRequest](request.Payload)
		if err == nil {
			err = xray.SetLogLevel(request.Level)
		}
		return encodeInvokeResponse(map[string]string{"level": xray.LogLevel()}, err)
	case LibXrayMethodReadLogs:
		request, err := decodePayload[ReadLogsRequest](request.Payload)
		if err != nil {
			return encodeInvokeResponse(nil, err)
		}
		logs := xray.ReadLogs(request.After)
		return encodeInvokeResponse(&logs, nil)
	case LibXrayMethodSocketPathChanged:
		// The Apple path monitor: sockets would now leave through another interface.
		internet.SocketPathChanged()
		return encodeInvokeNoDataResponse(nil)
	default:
		return encodeInvokeResponse(nil, errors.New("unknown method"))
	}
}

func invokeSetMemoryLimit(payload json.RawMessage) string {
	request, err := decodePayload[SetMemoryLimitRequest](payload)
	if err != nil || request.Bytes <= 0 {
		if err == nil {
			err = errors.New("memory limit must be positive")
		}
		return encodeInvokeResponse(nil, err)
	}
	return encodeInvokeResponse(&SetMemoryLimitResponse{
		PreviousBytes: xray.SetMemoryLimit(request.Bytes),
	}, nil)
}
func validateAPIVersion(version int) error {
	if version == 0 || version == 1 {
		return nil
	}
	return errors.New("unsupported apiVersion")
}

func decodePayload[T any](payload json.RawMessage) (T, error) {
	var request T
	if len(payload) == 0 {
		return request, nil
	}
	err := json.Unmarshal(payload, &request)
	return request, err
}

func encodeInvokeResponse(data any, err error) string {
	response := invokeResponse{Data: data}
	if err != nil {
		response.Success = false
		response.Err = err.Error()
	} else {
		response.Success = true
	}
	raw, err := json.Marshal(&response)
	if err != nil {
		return `{"success":false,"data":null,"error":"failed to encode response"}`
	}
	if len(raw) > maxInvokeJSONBytes {
		return encodeInvokeFailure(invokeJSONSizeLimitMessage("response"))
	}
	return string(raw)
}

func invokeJSONSizeLimitMessage(kind string) string {
	return fmt.Sprintf(
		"invoke %s exceeds the %d MiB size limit",
		kind,
		maxInvokeJSONSizeMiB,
	)
}

func encodeInvokeFailure(message string) string {
	raw, err := json.Marshal(&invokeResponse{Err: message})
	if err != nil {
		return `{"success":false,"data":null,"error":"failed to encode response"}`
	}
	return string(raw)
}

func encodeInvokeNoDataResponse(err error) string {
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	return encodeInvokeResponse(struct{}{}, nil)
}

func invokeGetFreePorts(payload json.RawMessage) string {
	request, err := decodePayload[GetFreePortsRequest](payload)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	ports, err := nodep.GetFreePorts(request.Count)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	return encodeInvokeResponse(&GetFreePortsResponse{Ports: ports}, nil)
}

func invokeConvertShareLinksToXrayJson(payload json.RawMessage) string {
	request, err := decodePayload[ConvertShareLinksToXrayJsonRequest](payload)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	xrayJson, err := share.ConvertShareLinksToXrayJson(request.Text)
	return encodeInvokeResponse(xrayJson, err)
}

func invokeConvertXrayJsonToShareLinks(payload json.RawMessage) string {
	request, err := decodePayload[ConvertXrayJsonToShareLinksRequest](payload)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	links, err := share.ConvertXrayJsonToShareLinks([]byte(request.XrayJson))
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	return encodeInvokeResponse(&ConvertXrayJsonToShareLinksResponse{Links: links}, nil)
}

func invokeCountGeoData(payload json.RawMessage) string {
	request, err := decodePayload[CountGeoDataRequest](payload)
	if err != nil {
		return encodeInvokeNoDataResponse(err)
	}
	if request.DatDir == "" {
		return encodeInvokeNoDataResponse(errors.New("missing datDir"))
	}
	err = geo.CountGeoData(request.DatDir, request.Name, request.GeoType)
	return encodeInvokeNoDataResponse(err)
}

type probeOperation struct {
	ctx     context.Context
	cancel  context.CancelFunc
	started bool
}

const maxConcurrentProbes = 32

var probeOperations = struct {
	sync.Mutex
	items map[string]*probeOperation
}{items: make(map[string]*probeOperation)}

// Registration precedes dispatch, so cancellation cannot race a future start.
func invokeProbeOperation(method LibXrayMethod, payload json.RawMessage) string {
	request, err := decodePayload[PingRequest](payload)
	if err != nil || len(request.OperationID) != 36 {
		return encodeInvokeResponse(nil, errors.New("invalid_probe_operation"))
	}
	for _, c := range request.OperationID {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c == '-') {
			return encodeInvokeResponse(nil, errors.New("invalid_probe_operation"))
		}
	}
	probeOperations.Lock()
	defer probeOperations.Unlock()
	op := probeOperations.items[request.OperationID]
	if method == LibXrayMethodPrepareProbe {
		if op != nil || len(probeOperations.items) >= maxConcurrentProbes || request.Timeout < 1 || request.Timeout > 15 {
			return encodeInvokeResponse(nil, errors.New("probe_admission_failed"))
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(request.Timeout)*time.Second)
		probeOperations.items[request.OperationID] = &probeOperation{ctx: ctx, cancel: cancel}
	} else if op != nil {
		op.cancel()
		if method == LibXrayMethodReleaseProbe && !op.started {
			delete(probeOperations.items, request.OperationID)
		}
	}
	return encodeInvokeResponse(map[string]bool{"accepted": true}, nil)
}

func invokePing(payload json.RawMessage) string {
	request, err := decodePayload[PingRequest](payload)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}
	if request.ExpectedStatus < 200 || request.ExpectedStatus >= 300 || request.ExpectedBody == nil ||
		len(*request.ExpectedBody) > 4096 || request.Timeout < 1 || request.Timeout > 15 ||
		(request.Method != "GET" && request.Method != "HEAD") ||
		(request.Method == "HEAD" && *request.ExpectedBody != "") ||
		// A trace reads the body, which a config-path probe never sees.
		(request.Trace && (request.Method != "GET" || request.ConfigJSON == "" && !request.RunningCore && !request.PacketPath)) {
		return encodeInvokeResponse(nil, errors.New("invalid_response_contract"))
	}
	expected := &nodep.ExpectedResponse{Status: request.ExpectedStatus, Body: *request.ExpectedBody}
	if request.Trace {
		expected.Trace = &nodep.Exit{}
	}
	// Only a passed check names the exit; Trace is nil unless asked for.
	exit := func(err error) *nodep.Exit {
		if err != nil {
			return nil
		}
		return expected.Trace
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(request.Timeout)*time.Second)
	defer cancel()
	if request.OperationID != "" {
		probeOperations.Lock()
		op := probeOperations.items[request.OperationID]
		if op == nil || op.started {
			probeOperations.Unlock()
			return encodeInvokeResponse(nil, errors.New("invalid_probe_operation"))
		}
		op.started = true
		ctx = op.ctx
		probeOperations.Unlock()
		defer func() {
			probeOperations.Lock()
			op.cancel()
			delete(probeOperations.items, request.OperationID)
			probeOperations.Unlock()
		}()
		if request.ConfigJSON == "" && !request.PacketPath {
			return encodeInvokeResponse(nil, errors.New("invalid_probe_operation"))
		}
	}
	if err := ctx.Err(); err != nil {
		return encodeInvokeResponse(nil, errors.New(probe.Code(err)))
	}
	if request.RunningCore {
		if request.ConfigJSON != "" || request.ConfigPath != "" || request.Proxy != "" || request.PacketPath {
			return encodeInvokeResponse(nil, errors.New("invalid_running_core_probe"))
		}
		delay, err := xray.PingRunningCore(ctx, request.Timeout, request.URL, request.Method, expected)
		return encodeInvokeResponse(&PingResponse{Delay: delay, Exit: exit(err)}, err)
	}
	if request.PacketPath {
		if request.ConfigJSON != "" || request.ConfigPath != "" || request.Proxy != "" {
			return encodeInvokeResponse(nil, errors.New("invalid_packet_probe"))
		}
		ctx, recorder := probe.New(ctx, "")
		probe.Emit(ctx, "request_begin", nil, 0)
		delay, err := nodep.MeasureDelayContext(ctx, request.Timeout, request.URL, "", request.Method, request.Mode, expected)
		probe.Emit(ctx, "request_end", err, 0)
		id, events := recorder.Snapshot()
		stage, code := packetProbeFailure(err)
		diagnostic := &xray.ProbeDiagnostics{
			ProbeID: id, Events: events, Code: code, Stage: stage,
			TransportCode: probe.Code(err), CleanupState: "not_started",
		}
		for _, event := range events {
			if event.Stage == "target_response" {
				diagnostic.HTTPStatus = event.Status
			}
		}
		if err != nil {
			err = errors.New(diagnostic.Code)
		}
		return encodeInvokeResponse(&PingResponse{Delay: delay, Diagnostics: diagnostic, Exit: exit(err)}, err)
	}
	var delay int64
	if request.ConfigJSON != "" {
		var diagnostic *xray.ProbeDiagnostics
		delay, diagnostic, err = xray.PingJSONWithPreparation(ctx, request.ConfigJSON, request.Timeout, request.URL, request.Proxy, request.Method, request.Mode, request.DiagnosticVariant,
			func() (func(), error) { return prepareProbeAssets(request.AndroidAssetDirectory) }, expected)
		if err != nil {
			err = fmt.Errorf("%s", diagnostic.Code)
		}
		return encodeInvokeResponse(&PingResponse{Delay: delay, Diagnostics: diagnostic, Exit: exit(err)}, err)
	} else {
		delay, err = xray.PingWithOptions(request.ConfigPath, request.Timeout, request.URL, request.Proxy, request.Method, request.Mode, expected)
	}
	if err != nil {
		if delay == nodep.PingDelayError || delay == nodep.PingDelayTimeout {
			return encodeInvokeResponse(&PingResponse{Delay: delay}, err)
		}
		return encodeInvokeResponse(nil, err)
	}
	return encodeInvokeResponse(&PingResponse{Delay: delay}, nil)
}

func packetProbeFailure(err error) (string, string) {
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "target_dns", "target_dns_failed"
	}
	return "target_request", probe.Code(err)
}

func invokePingBatch(payload json.RawMessage) string {
	request, err := decodePayload[PingBatchRequest](payload)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}

	configs := make([]xray.PingBatchItem, len(request.Configs))
	for i, config := range request.Configs {
		configs[i] = xray.PingBatchItem{
			ConfigPath:  config.ConfigPath,
			OutboundTag: config.OutboundTag,
		}
	}

	results, err := xray.PingBatch(
		configs,
		request.Timeout,
		request.URL,
	)
	if err != nil {
		return encodeInvokeResponse(nil, err)
	}

	responseResults := make([]PingBatchItemResponse, len(results))
	for i, result := range results {
		responseResults[i] = PingBatchItemResponse{
			Success: result.Success,
			Delay:   result.Delay,
			Error:   result.Error,
		}
	}
	return encodeInvokeResponse(&PingBatchResponse{Results: responseResults}, nil)
}

func invokeTestXray(payload json.RawMessage) string {
	request, err := decodePayload[RunXrayRequest](payload)
	if err != nil {
		return encodeInvokeNoDataResponse(err)
	}
	err = xray.TestXray(request.ConfigPath)
	return encodeInvokeNoDataResponse(err)
}

func invokeRunXray(payload json.RawMessage) string {
	request, err := decodePayload[RunXrayRequest](payload)
	if err != nil {
		return encodeInvokeNoDataResponse(err)
	}
	err = xray.RunXray(request.ConfigPath)
	return encodeInvokeNoDataResponse(err)
}

func invokeRunXrayFromJSON(payload json.RawMessage) string {
	request, err := decodePayload[RunXrayFromJSONRequest](payload)
	if err != nil {
		return encodeInvokeNoDataResponse(err)
	}
	err = xray.RunXrayFromJSON(request.ConfigJSON)
	return encodeInvokeNoDataResponse(err)
}
