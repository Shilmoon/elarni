//go:build !elarni_recording && !elarni_diagnostics

package flightrecorder

import (
	"context"
	"errors"
	"net"
)

// Builds without the recording option carry no collector; its instrumentation compiles away.

var errInvalid = errors.New("diagnostics unavailable in this build")

// ErrEmpty means an export found no recording to package.
var ErrEmpty = errors.New("diagnostics recording is empty")

func Enabled() bool                                                                    { return false }
func Record(Event)                                                                     {}
func NextID() uint64                                                                   { return 0 }
func WithConnection(ctx context.Context, _ uint64) context.Context                     { return ctx }
func Connection(context.Context) uint64                                                { return 0 }
func TrackConn(conn net.Conn, _ uint64, _ uint32, _ string) net.Conn                   { return conn }
func TrackPacketConn(conn net.PacketConn, _ uint64, _ uint32, _ string) net.PacketConn { return conn }
func command(r Request) (any, error) {
	if r.Action == "status" {
		return map[string]any{"enabled": false, "collecting": false}, nil
	}
	return nil, errInvalid
}
