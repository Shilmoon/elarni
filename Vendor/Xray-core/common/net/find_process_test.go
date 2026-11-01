//go:build (darwin && !ios) || windows || (linux && !android)

package net_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/xtls/xray-core/app/router"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/dns"
	routingdns "github.com/xtls/xray-core/features/routing/dns"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

type processTestDNS struct{ dns.Client }

func (processTestDNS) LookupIP(string, dns.IPOption) ([]xnet.IP, uint32, error) {
	return []xnet.IP{xnet.ParseIP("192.0.2.123")}, 60, nil
}

// The child keeps its TCP and UDP sockets open while the parent attributes them.
// This exercises foreign-process lookup without installing or starting a VPN.
func TestFindProcessChild(t *testing.T) {
	address := os.Getenv("ELARNI_PROCESS_FIXTURE")
	if address == "" {
		return
	}
	tcp, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	udp, err := net.Dial("udp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	if _, err := udp.Write([]byte("fixture")); err != nil {
		t.Fatal(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode([]string{tcp.LocalAddr().String(), udp.LocalAddr().String()}); err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func TestFindProcessAttributesForeignTCPAndUDP(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "::1"} {
		t.Run(ip, func(t *testing.T) {
			listener, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			udp, err := net.ListenPacket("udp", listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer udp.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			executable, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			cmd := exec.CommandContext(ctx, executable, "-test.run=^TestFindProcessChild$")
			cmd.Env = append(os.Environ(), "ELARNI_PROCESS_FIXTURE="+listener.Addr().String())
			cmd.Stderr = os.Stderr
			out, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			in, err := cmd.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { in.Close(); cancel(); cmd.Wait() }()
			var sources []string
			if err := json.NewDecoder(out).Decode(&sources); err != nil {
				t.Fatal(err)
			}
			if len(sources) != 2 {
				t.Fatal("missing fixture sockets")
			}
			for index, network := range []string{"tcp", "udp"} {
				source, err := net.ResolveTCPAddr("tcp", sources[index])
				if err != nil {
					t.Fatal(err)
				}
				pid, name, path, err := xnet.FindProcess(network, source.IP.String(), uint16(source.Port), ip, uint16(listener.Addr().(*net.TCPAddr).Port))
				if err != nil {
					t.Fatalf("%s attribution: %v", network, err)
				}
				expected := filepath.Base(executable)
				if runtime.GOOS == "windows" {
					expected = strings.TrimSuffix(expected, ".exe")
				}
				if pid != cmd.Process.Pid || name != expected || !filepath.IsAbs(filepath.FromSlash(path)) {
					t.Fatalf("%s attributed to pid=%d name=%s; expected pid=%d name=%s", network, pid, name, cmd.Process.Pid, expected)
				}
				// Sniffing/FakeDNS and IPOnDemand must not replace the OS socket's
				// remote endpoint with a freshly resolved address during lookup.
				original := xnet.DestinationFromAddr(listener.Addr())
				origin := xnet.DestinationFromAddr(source)
				if network == "udp" {
					original.Network, origin.Network = xnet.Network_UDP, xnet.Network_UDP
				}
				target := original
				target.Address = xnet.DomainAddress("sniffed.example")
				routingContext := &routingsession.Context{
					Inbound:  &session.Inbound{Source: origin},
					Outbound: &session.Outbound{Target: target, OriginalTarget: original},
				}
				resolved := routingdns.ContextWithDNSClient(routingContext, processTestDNS{})
				if !router.NewProcessNameMatcher([]string{path}).Apply(resolved) {
					t.Fatalf("%s sniffing/DNS lost the originating process", network)
				}
			}
		})
	}
}
