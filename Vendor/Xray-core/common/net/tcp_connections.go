package net

import (
	"errors"
	"net/netip"
)

// Elarni: a connection that a program opened before the tunnel started keeps its old route on
// Windows, and may on other systems, so a listed app's connection could skip per-app routing
// until the app reconnects. The core lists such connections after it starts and resets those
// the system lets it reset; the app then reconnects through the tunnel.

// TCPConnection is an established TCP connection of a program on this computer.
type TCPConnection struct {
	Local, Remote netip.AddrPort
	PID           int
}

// ErrResetUnsupported means this system cannot close this connection for its program.
var ErrResetUnsupported = errors.New("this connection cannot be reset here")
