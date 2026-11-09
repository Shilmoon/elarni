// libXray is an Xray wrapper focusing on improving the experience of Xray-core mobile development.
package libXray

import (
	"encoding/json"
	"github.com/xtls/libxray/nodep"
	"github.com/xtls/libxray/xray"
)

type LibXrayMethod string

const (
	LibXrayMethodGetFreePorts                LibXrayMethod = "getFreePorts"
	LibXrayMethodConvertShareLinksToXrayJson LibXrayMethod = "convertShareLinksToXrayJson"
	LibXrayMethodImportClientProfiles        LibXrayMethod = "importClientProfiles"
	LibXrayMethodNormalizeClientInput        LibXrayMethod = "normalizeClientInput"
	LibXrayMethodClientQR                    LibXrayMethod = "clientQR"
	LibXrayMethodProfileHostMappings         LibXrayMethod = "profileHostMappings"
	LibXrayMethodConvertXrayJsonToShareLinks LibXrayMethod = "convertXrayJsonToShareLinks"
	LibXrayMethodCountGeoData                LibXrayMethod = "countGeoData"
	LibXrayMethodPing                        LibXrayMethod = "ping"
	LibXrayMethodPrepareProbe                LibXrayMethod = "prepareProbe"
	LibXrayMethodCancelProbe                 LibXrayMethod = "cancelProbe"
	LibXrayMethodReleaseProbe                LibXrayMethod = "releaseProbe"
	LibXrayMethodFetchSubscription           LibXrayMethod = "fetchSubscription"
	LibXrayMethodFetchResource               LibXrayMethod = "fetchResource"
	LibXrayMethodPrepareFetch                LibXrayMethod = "prepareFetch"
	LibXrayMethodCancelFetch                 LibXrayMethod = "cancelFetch"
	LibXrayMethodReleaseFetch                LibXrayMethod = "releaseFetch"
	LibXrayMethodRunXrayFromJson             LibXrayMethod = "runXrayFromJson"
	LibXrayMethodStopXray                    LibXrayMethod = "stopXray"
	LibXrayMethodXrayVersion                 LibXrayMethod = "xrayVersion"
	LibXrayMethodGetXrayState                LibXrayMethod = "getXrayState"
	LibXrayMethodSetMemoryLimit              LibXrayMethod = "setMemoryLimit"
	LibXrayMethodGetRuntimeMetrics           LibXrayMethod = "getRuntimeMetrics"
	LibXrayMethodSetLogLevel                 LibXrayMethod = "setLogLevel"
	LibXrayMethodReadLogs                    LibXrayMethod = "readLogs"
	LibXrayMethodSocketPathChanged           LibXrayMethod = "socketPathChanged"
)

type LibXrayInvokeRequest struct {
	APIVersion int             `json:"apiVersion,omitempty"`
	Method     LibXrayMethod   `json:"method,omitempty"`
	Payload    json.RawMessage `json:"payload,omitempty"`
}

type SetMemoryLimitRequest struct {
	Bytes int64 `json:"bytes"`
}

type SetLogLevelRequest struct {
	Level string `json:"level"`
}

type ReadLogsRequest struct {
	After int64 `json:"after"`
}

type SetMemoryLimitResponse struct {
	PreviousBytes int64 `json:"previousBytes"`
}

type GetFreePortsRequest struct {
	Count int `json:"count,omitempty"`
}

type GetFreePortsResponse struct {
	Ports []int `json:"ports,omitempty"`
}

type ConvertShareLinksToXrayJsonRequest struct {
	Text string `json:"text,omitempty"`
}

type ClientImportRequest struct {
	Text             string            `json:"text"`
	SourceURL        string            `json:"sourceURL,omitempty"`
	MigrationHeaders map[string]string `json:"migrationHeaders,omitempty"`
}

type ConvertXrayJsonToShareLinksRequest struct {
	XrayJson string `json:"xrayJson,omitempty"`
}

type ConvertXrayJsonToShareLinksResponse struct {
	Links string `json:"links,omitempty"`
}

type CountGeoDataRequest struct {
	Name    string `json:"name,omitempty"`
	GeoType string `json:"geoType,omitempty"`
	DatDir  string `json:"datDir,omitempty"`
}

type PingRequest struct {
	AndroidAssetDirectory *string `json:"androidAssetDirectory,omitempty"`
	OperationID           string  `json:"operationId,omitempty"`
	ConfigJSON            string  `json:"configJSON,omitempty"`
	Timeout               int     `json:"timeout,omitempty"`
	URL                   string  `json:"url,omitempty"`
	Proxy                 string  `json:"proxy,omitempty"`
	Method                string  `json:"method,omitempty"`
	Mode                  string  `json:"mode,omitempty"`
	DiagnosticVariant     string  `json:"diagnosticVariant,omitempty"`
	ExpectedStatus        int     `json:"expectedStatus,omitempty"`
	ExpectedBody          *string `json:"expectedBody,omitempty"`
	PacketPath            bool    `json:"packetPath,omitempty"`
	RunningCore           bool    `json:"runningCore,omitempty"`
	// Trace reads Cloudflare's /cdn-cgi/trace at URL to name the server's exit.
	Trace bool `json:"trace,omitempty"`
}

type PingResponse struct {
	Delay       int64                  `json:"delay"`
	Diagnostics *xray.ProbeDiagnostics `json:"diagnostics,omitempty"`
	Exit        *nodep.Exit            `json:"exit,omitempty"`
}

type RunXrayFromJSONRequest struct {
	ConfigJSON string `json:"configJSON,omitempty"`
}

type XrayVersionResponse struct {
	Version string `json:"version,omitempty"`
}

type GetXrayStateResponse struct {
	Running bool `json:"running"`
}
