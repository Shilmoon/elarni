package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/xtls/xray-core/common/flightrecorder"
)

// The user's Settings switch starts the flight recorder inside whichever core
// process carries traffic; the app's one-shot cores only mark and export.

func diagnosticsCommand(request flightrecorder.Request) error {
	data, err := json.Marshal(request)
	if err != nil {
		return err
	}
	_, err = flightrecorder.Command(data)
	return err
}

func userRecordingDirectory() string {
	cache, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(cache, "Elarni", "Diagnostics")
}

// startRecording records one core run when the user asked for it. A diagnostic
// build already records for the whole process, so its collector is left running.
func startRecording(enabled bool, directory string, owner int) (stop func()) {
	if !enabled || directory == "" || flightrecorder.Enabled() {
		return func() {}
	}
	if diagnosticsCommand(flightrecorder.Request{Action: "start", Directory: directory, Role: "helper", Owner: owner}) != nil {
		return func() {}
	}
	return func() { _ = diagnosticsCommand(flightrecorder.Request{Action: "stop"}) }
}

// recordingRequest serves the app's Mark and Export. The directories come from
// this process, never from the request, so callers cannot aim the core elsewhere.
func recordingRequest(payload json.RawMessage) (any, error) {
	var request struct {
		Action      string `json:"action"`
		Destination string `json:"destination"`
	}
	if json.Unmarshal(payload, &request) != nil {
		return nil, errors.New("invalid_request")
	}
	var directories []string
	for _, directory := range recordingDirectories() {
		if directory != "" {
			directories = append(directories, directory)
		}
	}
	if len(directories) == 0 {
		return nil, errors.New("recording_failed")
	}
	switch request.Action {
	case "mark":
		// The recording core may be elevated, so the mark goes in a small file of the app's own beside it.
		if !flightrecorder.Enabled() {
			if diagnosticsCommand(flightrecorder.Request{Action: "start", Directory: directories[0], Role: "host"}) != nil {
				return nil, errors.New("recording_failed")
			}
			defer diagnosticsCommand(flightrecorder.Request{Action: "stop"})
		}
		if diagnosticsCommand(flightrecorder.Request{Action: "mark"}) != nil {
			return nil, errors.New("recording_failed")
		}
		return map[string]any{}, nil
	case "export":
		err := diagnosticsCommand(flightrecorder.Request{Action: "export", Directories: directories, Destination: request.Destination})
		if errors.Is(err, flightrecorder.ErrEmpty) {
			return nil, errors.New("recording_empty")
		}
		if err != nil {
			return nil, errors.New("recording_failed")
		}
		return map[string]any{}, nil
	}
	return nil, errors.New("invalid_request")
}

func diagnosticsRequest(method string, raw json.RawMessage) {
	if method != "runVPN" && method != "runXrayFromJson" {
		return
	}
	var request struct {
		ConfigJSON                                          string
		MemoryLimitMB, TCPMaxConnections, UDPMaxConnections int
		RecordDiagnostics                                   bool
	}
	if json.Unmarshal(raw, &request) != nil {
		return
	}
	// The local proxy core records for as long as its process lives; an elevated VPN core starts its own.
	if method == "runXrayFromJson" {
		startRecording(request.RecordDiagnostics, userRecordingDirectory(), 0)
	}
	recordRuntimeConfig(request.ConfigJSON, request.MemoryLimitMB, request.TCPMaxConnections, request.UDPMaxConnections, method == "runVPN")
}

func recordRuntimeConfig(configJSON string, memoryLimitMB, tcpMaxConnections, udpMaxConnections int, vpn bool) {
	if !flightrecorder.Enabled() {
		return
	}
	var config struct {
		Inbounds []struct {
			Protocol string
			Sniffing struct{ Enabled bool }
		}
		Outbounds []struct {
			Protocol       string
			StreamSettings struct{ Network, Security string }
		}
		Routing struct{ Rules []struct{ Process []string } }
		DNS     struct{ Servers []json.RawMessage }
	}
	if json.Unmarshal([]byte(configJSON), &config) != nil {
		return
	}
	values := map[string]int64{"memory_limit_mb": int64(memoryLimitMB), "tcp_limit": int64(tcpMaxConnections), "udp_limit": int64(udpMaxConnections), "dns_servers": int64(len(config.DNS.Servers))}
	if vpn {
		values["windows_vpn"] = 1
	}
	for _, inbound := range config.Inbounds {
		switch inbound.Protocol {
		case "tun", "socks", "http":
			values["inbound_"+inbound.Protocol]++
		}
		if inbound.Sniffing.Enabled {
			values["sniffing"]++
		}
	}
	for _, outbound := range config.Outbounds {
		switch outbound.Protocol {
		case "vless", "vmess", "wireguard", "amneziawg", "hysteria", "tuic", "trojan", "shadowsocks", "freedom", "blackhole", "dns":
			values["outbound_"+outbound.Protocol]++
		}
		switch outbound.StreamSettings.Network {
		case "xhttp", "tcp", "grpc", "ws", "hysteria", "quic":
			values["transport_"+outbound.StreamSettings.Network]++
		}
		switch outbound.StreamSettings.Security {
		case "tls", "reality":
			values["security_"+outbound.StreamSettings.Security]++
		}
	}
	for _, rule := range config.Routing.Rules {
		if len(rule.Process) != 0 {
			values["process_rules"]++
			values["process_entries"] += int64(len(rule.Process))
		}
	}
	flightrecorder.Record(flightrecorder.Event{Name: "runtime_config", Values: values})
}

func diagnosticsFlush() {
	if flightrecorder.Enabled() {
		_ = diagnosticsCommand(flightrecorder.Request{Action: "flush"})
	}
}
