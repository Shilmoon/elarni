package libXray

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/xtls/libxray/share"
)

var fetchOperations = struct {
	sync.Mutex
	items map[string]*probeOperation
}{items: make(map[string]*probeOperation)}

// Prepare before dispatch. A cancelled or released ID can never start a fetch.
func invokeFetch(method LibXrayMethod, payload json.RawMessage) string {
	var request struct {
		share.SubscriptionFetchRequest
		OperationID  string `json:"operationId"`
		ResourceKind string `json:"resourceKind"`
	}
	if json.Unmarshal(payload, &request) != nil || len(request.OperationID) != 36 {
		return encodeInvokeResponse(nil, errors.New("invalid_fetch_operation"))
	}
	for _, c := range request.OperationID {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c == '-') {
			return encodeInvokeResponse(nil, errors.New("invalid_fetch_operation"))
		}
	}
	limit, timeout := int64(4*1024*1024), 30*time.Second
	if request.ResourceKind == "geofile" {
		limit, timeout = 64*1024*1024, 180*time.Second
	}
	if method == LibXrayMethodFetchResource && request.ResourceKind != "geofile" && request.ResourceKind != "domains" {
		return encodeInvokeResponse(nil, errors.New("invalid_resource_kind"))
	}
	fetching := method == LibXrayMethodFetchSubscription || method == LibXrayMethodFetchResource
	fetchOperations.Lock()
	op := fetchOperations.items[request.OperationID]
	if method == LibXrayMethodPrepareFetch {
		if op != nil || len(fetchOperations.items) >= 32 {
			fetchOperations.Unlock()
			return encodeInvokeResponse(nil, errors.New("fetch_admission_failed"))
		}
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		op = &probeOperation{ctx: ctx, cancel: cancel}
		fetchOperations.items[request.OperationID] = op
		context.AfterFunc(ctx, func() {
			fetchOperations.Lock()
			defer fetchOperations.Unlock()
			if fetchOperations.items[request.OperationID] == op && !op.started {
				delete(fetchOperations.items, request.OperationID)
			}
		})
	} else if fetching {
		if op == nil || op.started || op.ctx.Err() != nil {
			fetchOperations.Unlock()
			return encodeInvokeResponse(nil, errors.New("fetch_cancelled"))
		}
		op.started = true
	} else if op != nil {
		op.cancel()
		if method == LibXrayMethodReleaseFetch && !op.started {
			delete(fetchOperations.items, request.OperationID)
		}
	}
	fetchOperations.Unlock()
	if !fetching {
		return encodeInvokeResponse(map[string]bool{"accepted": true}, nil)
	}
	defer func() {
		fetchOperations.Lock()
		defer fetchOperations.Unlock()
		op.cancel()
		delete(fetchOperations.items, request.OperationID)
	}()
	if method == LibXrayMethodFetchResource {
		result, err := share.FetchResource(op.ctx, request.SubscriptionFetchRequest, limit, timeout, true)
		if err != nil {
			return encodeInvokeResponse(nil, err)
		}
		// Geofiles are capped at 64 MiB before base64 encoding. Only this binary
		// operation has the larger response budget; ordinary FFI stays at 16 MiB.
		raw, err := json.Marshal(invokeResponse{Success: true, Data: result})
		if err != nil || len(raw) > 96*1024*1024 {
			return encodeInvokeResponse(nil, errors.New("resource_response_too_large"))
		}
		return string(raw)
	}
	result, err := share.FetchSubscription(op.ctx, request.SubscriptionFetchRequest)
	return encodeInvokeResponse(result, err)
}
