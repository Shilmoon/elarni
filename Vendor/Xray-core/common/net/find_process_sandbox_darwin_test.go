//go:build darwin && !ios

package net_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/xtls/xray-core/app/router"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	routing_session "github.com/xtls/xray-core/features/routing/session"
)

type sandboxProcessFixture struct {
	PID   int
	Path  string
	Flows []struct{ Network, Source, Target string }
}

func TestFindProcessSandboxHelper(t *testing.T) {
	input := os.Getenv("ELARNI_SANDBOX_PROCESS_FIXTURE")
	if input == "" {
		return
	}
	var fixture sandboxProcessFixture
	if err := json.Unmarshal([]byte(input), &fixture); err != nil {
		t.Fatal(err)
	}
	for _, flow := range fixture.Flows {
		source, err := net.ResolveTCPAddr("tcp", flow.Source)
		if err != nil {
			t.Fatal(err)
		}
		target, err := net.ResolveTCPAddr("tcp", flow.Target)
		if err != nil {
			t.Fatal(err)
		}
		pid, _, path, err := xnet.FindProcess(flow.Network, source.IP.String(), uint16(source.Port), target.IP.String(), uint16(target.Port))
		if err != nil {
			t.Fatalf("sandbox %s %s lookup: %v", flow.Network, source.IP, err)
		}
		path, err = filepath.EvalSymlinks(path)
		if err != nil || pid != fixture.PID || path != fixture.Path {
			t.Fatalf("foreign socket attributed to wrong process: pid=%d path=%q err=%v", pid, path, err)
		}
		network := xnet.Network_TCP
		if flow.Network == "udp" {
			network = xnet.Network_UDP
		}
		routing := &routing_session.Context{
			Inbound:  &session.Inbound{Tag: "elarni-tun", Source: xnet.Destination{Network: network, Address: xnet.IPAddress(source.IP), Port: xnet.Port(source.Port)}},
			Outbound: &session.Outbound{Target: xnet.Destination{Network: network, Address: xnet.IPAddress(target.IP), Port: xnet.Port(target.Port)}},
		}
		if !router.NewProcessNameMatcher([]string{filepath.Dir(path) + "/"}).Apply(routing) || router.NewProcessNameMatcher([]string{"/Applications/UnselectedFixture.app/"}).Apply(routing) {
			t.Fatal("sandbox app folder selection did not distinguish selected and unselected processes")
		}
	}
}

// Only the lookup runs sandboxed. The sockets belong to this unsandboxed parent,
// so a same-sandbox child test cannot accidentally hide the extension's denial.
func TestFindProcessFromAppSandbox(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatal(err)
	}
	fixture := sandboxProcessFixture{PID: os.Getpid(), Path: executable}
	for _, ip := range []string{"127.0.0.1", "::1"} {
		listener, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		for _, network := range []string{"tcp", "udp"} {
			conn, err := net.Dial(network, listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			fixture.Flows = append(fixture.Flows, struct{ Network, Source, Target string }{network, conn.LocalAddr().String(), conn.RemoteAddr().String()})
		}
		// Browsers also send UDP from wildcard-bound, unconnected sockets.
		network := "udp4"
		if ip == "::1" {
			network = "udp6"
		}
		udp, err := net.ListenUDP(network, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer udp.Close()
		target, err := net.ResolveUDPAddr(network, listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := udp.WriteToUDP([]byte("fixture"), target); err != nil {
			t.Fatal(err)
		}
		fixture.Flows = append(fixture.Flows, struct{ Network, Source, Target string }{"udp", net.JoinHostPort(ip, fmt.Sprint(udp.LocalAddr().(*net.UDPAddr).Port)), target.String()})
	}
	root := t.TempDir()
	app := filepath.Join(root, "LookupFixture.app")
	binary := filepath.Join(app, "Contents", "MacOS", "LookupFixture")
	if err := os.MkdirAll(filepath.Dir(binary), 0700); err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	output, err := os.OpenFile(binary, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0700)
	if err != nil {
		t.Fatal(err)
	}
	_, copyErr := io.Copy(output, source)
	closeErr := output.Close()
	if copyErr != nil || closeErr != nil {
		t.Fatalf("copy test executable: %v %v", copyErr, closeErr)
	}
	info := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.elarni.process-checks</string><key>CFBundleExecutable</key><string>LookupFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`
	if err := os.WriteFile(filepath.Join(app, "Contents", "Info.plist"), []byte(info), 0600); err != nil {
		t.Fatal(err)
	}
	entitlements := filepath.Join(root, "sandbox.entitlements")
	if err := os.WriteFile(entitlements, []byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/><key>com.apple.security.network.server</key><true/></dict></plist>`), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "codesign", "--force", "--sign", "-", "--entitlements", entitlements, app).CombinedOutput(); err != nil {
		t.Fatalf("sign sandbox fixture: %v\n%s", err, output)
	}
	input, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, binary, "-test.run=^TestFindProcessSandboxHelper$", "-test.v")
	cmd.Env = append(os.Environ(), "ELARNI_SANDBOX_PROCESS_FIXTURE="+string(input))
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("sandbox foreign-process routing: %v\n%s", err, output)
	}
	fmt.Println("PASS sandbox foreign-process TCP/UDP IPv4/IPv6 and app folder selection")
}
