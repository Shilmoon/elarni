//go:build (darwin || android) && elarni_integration

package share

/*
#cgo CFLAGS: -I${SRCDIR}/../../../include
#cgo darwin LDFLAGS: -L${SRCDIR}/../../../.build/rust-macos/current -lelarni_domain -lSystem -lc -lm
#cgo android,arm64 LDFLAGS: -L${SRCDIR}/../../../.build/android-native/jniLibs/arm64-v8a
#cgo android,amd64 LDFLAGS: -L${SRCDIR}/../../../.build/android-native/jniLibs/x86_64
#cgo android LDFLAGS: -lelarni_domain -llog -ldl -lm
#include "elarni_ffi.h"
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"
)

func compileElarniOutboundFFI(outbound json.RawMessage) ([]byte, error) {
	return compileElarniFFI("compileOutbound", map[string]any{
		"outbound": outbound,
		"routes": map[string]any{
			"rules":          []any{},
			"dnsServers":     []string{"198.18.0.1"},
			"staticHosts":    map[string]any{},
			"fallbackAction": "proxy",
		},
		"socksPort": 1080,
	})
}

func compileElarniProfileFFI(profile json.RawMessage, socksPort int) ([]byte, error) {
	return compileElarniFFI("compileProfile", map[string]any{"profile": profile, "socksPort": socksPort})
}

func compileElarniFFI(operation string, payload map[string]any) ([]byte, error) {
	request, err := json.Marshal(map[string]any{"schemaVersion": 1, "operation": operation, "payload": payload})
	if err != nil {
		return nil, err
	}
	handle := C.elarni_handle_new()
	if handle == nil {
		return nil, fmt.Errorf("elarni handle allocation failed")
	}
	defer C.elarni_handle_free(handle)
	var output C.ElarniBuffer
	status := C.elarni_request(
		handle,
		(*C.uint8_t)(unsafe.Pointer(&request[0])),
		C.size_t(len(request)),
		&output,
	)
	defer C.elarni_buffer_free(output)
	if status != C.ELARNI_STATUS_OK || output.data == nil {
		return nil, fmt.Errorf("elarni compile failed with status %d", status)
	}
	responseData := C.GoBytes(unsafe.Pointer(output.data), C.int(output.len))
	var response struct {
		Config string `json:"configUtf8"`
	}
	if err := json.Unmarshal(responseData, &response); err != nil {
		return nil, err
	}
	if response.Config == "" {
		return nil, fmt.Errorf("elarni returned an empty config")
	}
	return []byte(response.Config), nil
}
