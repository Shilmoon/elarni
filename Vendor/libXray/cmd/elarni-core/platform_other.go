//go:build !windows && !linux

package main

import (
	"encoding/json"
	"errors"
	"github.com/xtls/libxray/xray"
	"runtime"
)

func deviceVersion() string { return runtime.GOOS }

func recordingDirectories() []string { return []string{userRecordingDirectory()} }

func platformMain() (bool, int) { return false, 0 }
func platformRunning() bool     { return false }
func platformTunnelUp() bool    { return false }
func platformStop() error       { return nil }
func platformMetrics() (xray.RuntimeMetrics, error) {
	return xray.RuntimeMetrics{}, errors.New("not_running")
}

func platformRequest(method string, payload json.RawMessage) (any, error, bool) {
	return nil, nil, false
}
