package wireguard

import (
	"context"
	"net/netip"

	xctx "github.com/xtls/xray-core/common/ctx"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/probe"
)

func diagnosticFamily(addr netip.Addr) int64 {
	if !addr.IsValid() {
		return 0
	}
	if addr.Unmap().Is4() {
		return 4
	}
	return 6
}

func (h *Handler) diagnosticEvent(ctx context.Context, name string, err error, values map[string]int64) {
	if !flightrecorder.Enabled() {
		return
	}
	if values == nil {
		values = make(map[string]int64)
	}
	values["tunnel"] = int64(h.diagnosticID)
	flightrecorder.Record(flightrecorder.Event{Name: name, Code: probe.Code(err), Connection: flightrecorder.Connection(ctx), Session: uint32(xctx.IDFromContext(ctx)), Values: values})
}
