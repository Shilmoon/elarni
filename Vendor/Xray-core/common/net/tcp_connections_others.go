//go:build !(linux && !android) && !windows && !(darwin && !ios)

package net

// EstablishedTCPConnections is not available on this system.
func EstablishedTCPConnections() ([]TCPConnection, error) { return nil, ErrResetUnsupported }

// ResetTCPConnection is not available on this system.
func ResetTCPConnection(TCPConnection) error { return ErrResetUnsupported }
