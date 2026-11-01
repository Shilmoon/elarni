package share

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/google/uuid"
	TUIC "github.com/sagernet/sing-quic/tuic"
	sbuf "github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	ST "github.com/sagernet/sing/common/tls"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/probe"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/proxy/socks"
	"github.com/xtls/xray-core/transport/internet"
)

const tuicFixtureUUID = "00000000-0000-4000-8000-000000000001"
const tuicFixturePassword = "synthetic-p@ss:✓"

// The default fixture is the upstream test service, never a production inbound.
// ELARNI_TUIC_SERVER selects the independently built sing-box interoperability peer.
func TestImportedTUICClientsCarryLoopbackTraffic(t *testing.T) {
	for _, mode := range []string{"native", "quic"} {
		for _, host := range []string{"127.0.0.1", "::1"} {
			t.Run(mode+"/"+host, func(t *testing.T) {
				profile := tuicTrafficFixture(t, host, mode)
				for cycle := 0; cycle < 2; cycle++ {
					client, stop := startTrafficCore(t, profile)
					for _, destination := range []string{"127.0.0.1", "::1"} {
						trafficRoundTrip(t, client, "tcp", destination)
						trafficRoundTrip(t, client, "udp", destination)
					}
					trafficRoundTrip(t, client, "tcp", "127.0.0.1", "localhost")
					trafficRoundTrip(t, client, "udp", "127.0.0.1", "localhost")
					stop()
				}
			})
		}
	}
}

// SMTP, IMAP and MySQL servers greet first; their clients send nothing until then.
func TestTUICServerFirstProtocols(t *testing.T) {
	profile := tuicTrafficFixture(t, "127.0.0.1", "native")
	client, stop := startTrafficCore(t, profile)
	defer stop()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		peer, err := listener.Accept()
		if err != nil {
			return
		}
		defer peer.Close()
		peer.Write([]byte("220 synthetic banner\r\n"))
		io.Copy(io.Discard, peer)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := core.Dial(ctx, client, xnet.DestinationFromAddr(listener.Addr()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	banner := make([]byte, 64)
	n, err := conn.Read(banner)
	if string(banner[:n]) != "220 synthetic banner\r\n" {
		t.Fatalf("read %q, %v", banner[:n], err)
	}
}

// A client may half-close before the server greets, as `nc -N` does without
// input. The stream must still open, or the greeting never comes back.
func TestTUICServerFirstAfterClientHalfClose(t *testing.T) {
	profile := tuicTrafficFixture(t, "127.0.0.1", "native")
	port := trafficPort(t)
	profile["inbounds"] = []any{map[string]any{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": map[string]any{"auth": "noauth"}}}
	_, stop := startTrafficCore(t, profile)
	defer stop()
	serverFirstAfterHalfClose(t, port)
}

// The other outbounds buffer their request header with the first payload; a
// half-close before any payload must still send it.
func TestServerFirstAfterClientHalfClose(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	const password = "fixture-password"
	key := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16))
	serverTLS, clientTLS := trafficTLS(t)
	for _, fixture := range []struct {
		name, protocol string
		server, client object
		tls            bool
	}{
		{"VLESS", "vless", object{"clients": []any{object{"id": id}}, "decryption": "none"}, object{"id": id, "encryption": "none"}, false},
		{"VMess", "vmess", object{"clients": []any{object{"id": id}}}, object{"id": id, "security": "auto"}, false},
		{"Trojan TLS", "trojan", object{"clients": []any{object{"password": password}}}, object{"password": password}, true},
		{"Shadowsocks", "shadowsocks", object{"method": "chacha20-ietf-poly1305", "password": password, "network": "tcp"}, object{"method": "chacha20-ietf-poly1305", "password": password}, false},
		{"Shadowsocks 2022", "shadowsocks", object{"method": "2022-blake3-aes-128-gcm", "password": key, "network": "tcp"}, object{"method": "2022-blake3-aes-128-gcm", "password": key}, false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			port := trafficPort(t)
			serverStream, clientStream := object{"network": "raw"}, object{"network": "raw"}
			if fixture.tls {
				for k, v := range serverTLS {
					serverStream[k] = v
				}
				for k, v := range clientTLS {
					clientStream[k] = v
				}
			}
			_, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"},
				"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": fixture.protocol, "settings": fixture.server, "streamSettings": serverStream}},
				"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32"}}}}}}})
			defer stopServer()
			settings := object{"address": "127.0.0.1", "port": port}
			for k, v := range fixture.client {
				settings[k] = v
			}
			input, err := json.Marshal(object{"outbounds": []any{object{"tag": "proxy", "protocol": fixture.protocol, "settings": settings, "streamSettings": clientStream}}})
			if err != nil {
				t.Fatal(err)
			}
			imported, err := ImportClientProfiles(string(input))
			if err != nil {
				t.Fatal(err)
			}
			var profile object
			if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
				t.Fatal(err)
			}
			socksPort := trafficPort(t)
			profile["inbounds"] = []any{object{"listen": "127.0.0.1", "port": socksPort, "protocol": "socks", "settings": object{"auth": "noauth"}}}
			_, stopClient := startTrafficCore(t, profile)
			defer stopClient()
			serverFirstAfterHalfClose(t, socksPort)
		})
	}
}

// serverFirstAfterHalfClose half-closes a SOCKS stream through port before
// sending anything and expects the destination's greeting back.
func serverFirstAfterHalfClose(t *testing.T, port int) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		peer, err := listener.Accept()
		if err != nil {
			return
		}
		defer peer.Close()
		peer.Write([]byte("220 synthetic banner\r\n"))
		io.Copy(io.Discard, peer)
	}()
	control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(port)), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	control.SetDeadline(time.Now().Add(5 * time.Second))
	dest := xnet.DestinationFromAddr(listener.Addr())
	if _, err := socks.ClientHandshake(&protocol.RequestHeader{Command: protocol.RequestCommandTCP, Address: dest.Address, Port: dest.Port}, control, control); err != nil {
		t.Fatal(err)
	}
	if err := control.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	banner := make([]byte, len("220 synthetic banner\r\n"))
	if n, err := io.ReadFull(control, banner); string(banner[:n]) != "220 synthetic banner\r\n" {
		t.Fatalf("read %q, %v", banner[:n], err)
	}
}

func TestTUICAuthenticationTLSAndRequiredSocketFailures(t *testing.T) {
	for _, failure := range []string{"password", "uuid", "hostname", "untrusted", "expired", "unavailable", "blockedUDP", "controller"} {
		t.Run(failure, func(t *testing.T) {
			var expiry []time.Time
			if failure == "expired" {
				expiry = append(expiry, time.Now().Add(-time.Minute))
			}
			profile := tuicTrafficFixture(t, "127.0.0.1", "native", expiry...)
			outbound := profile["outbounds"].([]any)[0].(map[string]any)
			settings := outbound["settings"].(map[string]any)
			tls := outbound["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
			switch failure {
			case "password":
				settings["password"] = "incorrect-synthetic-password"
			case "uuid":
				settings["uuid"] = "00000000-0000-4000-8000-000000000002"
			case "hostname":
				tls["serverName"] = "wrong.example.invalid"
			case "untrusted":
				delete(tls, "certificates")
			case "unavailable":
				settings["port"] = trafficPort(t, "127.0.0.1")
			case "blockedUDP":
				// An independent socket drops every QUIC datagram, modeling a
				// reachable endpoint behind a UDP-blocking path.
				silent, err := net.ListenPacket("udp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { silent.Close() })
				settings["port"] = silent.LocalAddr().(*net.UDPAddr).Port
			}
			previous := internet.RequiredSocketController
			var calls atomic.Int64
			if failure == "controller" {
				internet.RequiredSocketController = func(network, address string, raw syscall.RawConn) error {
					calls.Add(1)
					if !strings.HasPrefix(network, "udp") {
						t.Error("TUIC bypassed UDP controller")
					}
					return fmt.Errorf("synthetic-protection-denied")
				}
				defer func() { internet.RequiredSocketController = previous }()
			}
			client, stop := startTrafficCore(t, profile)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			// A direct fallback would reach this independent listener and return the nonce.
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			reached := make(chan struct{}, 1)
			go func() {
				peer, err := listener.Accept()
				if err != nil {
					return
				}
				defer peer.Close()
				reached <- struct{}{}
				peer.SetDeadline(time.Now().Add(2 * time.Second))
				io.Copy(peer, peer)
			}()
			conn, err := core.Dial(ctx, client, xnet.DestinationFromAddr(listener.Addr()))
			if err == nil {
				closeOnCancel := context.AfterFunc(ctx, func() { conn.Close() })
				conn.Write([]byte("must-not-pass"))
				var result [1]byte
				_, err = conn.Read(result[:])
				conn.Close()
				closeOnCancel()
			}
			if err == nil {
				t.Fatal("invalid security produced successful traffic")
			}
			stop()
			select {
			case <-reached:
				t.Fatal("invalid security reached the target through a direct fallback")
			default:
			}
			if failure == "controller" && calls.Load() == 0 {
				t.Fatal("required controller was not invoked")
			}
		})
	}
}

// Exercise the public dispatcher: one canceled stream must not close the shared
// QUIC connection, and replies from multiple UDP peers retain packet boundaries.
func TestTUICConcurrentCancellationDatagramsAndCleanup(t *testing.T) {
	for _, mode := range []string{"native", "quic"} {
		t.Run(mode, func(t *testing.T) {
			profile := tuicTrafficFixture(t, "127.0.0.1", mode)
			profile["stats"] = map[string]any{}
			profile["policy"] = map[string]any{"system": map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true}}
			client, stop := startTrafficCore(t, profile)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			ctx, recorder := probe.New(ctx, "loopback.test")
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			go func() {
				for {
					peer, err := listener.Accept()
					if err != nil {
						return
					}
					go func() { defer peer.Close(); peer.SetDeadline(time.Now().Add(10 * time.Second)); io.Copy(peer, peer) }()
				}
			}()
			firstCtx, cancelFirst := context.WithCancel(ctx)
			first, err := core.Dial(firstCtx, client, xnet.DestinationFromAddr(listener.Addr()))
			if err != nil {
				t.Fatal(err)
			}
			defer first.Close()
			second, err := core.Dial(ctx, client, xnet.DestinationFromAddr(listener.Addr()))
			if err != nil {
				t.Fatal(err)
			}
			defer second.Close()
			stopReads := context.AfterFunc(ctx, func() { first.Close(); second.Close() })
			defer stopReads()
			for _, conn := range []net.Conn{first, second} {
				tuicEcho(t, conn, []byte("before-cancel-nonce"))
			}
			cancelFirst()
			first.Close()
			tuicEcho(t, second, []byte("surviving-stream-nonce"))
			packets, err := core.DialUDP(ctx, client)
			if err != nil {
				t.Fatal(err)
			}
			defer packets.Close()
			stopPackets := context.AfterFunc(ctx, func() { packets.Close() })
			defer stopPackets()
			// sing-box's direct peer binds its UDP socket from the first target
			// family. Starting with IPv6 gives that peer a dual-stack socket.
			for _, host := range []string{"::1", "127.0.0.1"} {
				peer, err := net.ListenPacket("udp", net.JoinHostPort(host, "0"))
				if err != nil {
					t.Fatal(err)
				}
				defer peer.Close()
				go func() {
					data := make([]byte, 65535)
					for {
						n, sender, err := peer.ReadFrom(data)
						if err != nil {
							return
						}
						peer.WriteTo(data[:n], sender)
					}
				}()
				for _, size := range []int{1, 1200, 1800} {
					payload := bytes.Repeat([]byte{byte(size % 251)}, size)
					if n, err := packets.WriteTo(payload, peer.LocalAddr()); err != nil || n != len(payload) {
						t.Fatalf("UDP write: %d %v", n, err)
					}
					data := make([]byte, 65535)
					n, source, err := packets.ReadFrom(data)
					if err != nil || !bytes.Equal(payload, data[:n]) || source.String() != peer.LocalAddr().String() {
						t.Fatalf("UDP payload/source changed: size=%d n=%d source=%v err=%v", size, n, source, err)
					}
				}
			}
			manager := client.GetFeature(stats.ManagerType()).(stats.Manager)
			for _, direction := range []string{"uplink", "downlink"} {
				counter := manager.GetCounter("outbound>>>proxy>>>traffic>>>" + direction)
				if counter == nil || counter.Value() < 6000 {
					t.Fatalf("TUIC %s traffic is not counted", direction)
				}
			}
			stop()
			// Close is idempotent and tracked sockets/work are joined after Stop.
			if err := client.Close(); err != nil {
				t.Fatal(err)
			}
			cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), time.Second)
			defer cleanupCancel()
			if !recorder.CloseTransport(cleanupCtx) {
				t.Fatal("TUIC Stop retained owned probe transport work")
			}
			t.Log("two live streams, canceled peer, six UDP datagrams with exact source/bytes, counters and joined transport cleanup")
		})
	}
}

func tuicEcho(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, data); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, payload) {
		t.Fatal("TCP nonce changed")
	}
}

func TestTUICStopDuringPendingHandshake(t *testing.T) {
	profile := tuicTrafficFixture(t, "127.0.0.1", "native")
	// An accepting UDP socket without a QUIC responder keeps the offer pending.
	silent, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	profile["outbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)["port"] = silent.LocalAddr().(*net.UDPAddr).Port
	client, stop := startTrafficCore(t, profile)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ctx, recorder := probe.New(ctx, "pending.test")
	conn, err := core.Dial(ctx, client, xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), 9))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("pending-nonce"))
	silent.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := silent.ReadFrom(make([]byte, 2048)); err != nil {
		t.Fatal("handshake did not reach the owned UDP socket", err)
	}
	ended := make(chan struct{})
	go func() { stop(); close(ended) }()
	select {
	case <-ended:
	case <-time.After(time.Second):
		t.Fatal("Stop blocked on pending QUIC handshake")
	}
	cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), time.Second)
	defer cleanupCancel()
	if !recorder.CloseTransport(cleanupCtx) {
		t.Fatal("pending offer leaked transport work")
	}
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("stopped handshake produced traffic")
	}
}

func TestTUICUDPUpstreamChainTraffic(t *testing.T) {
	profile := tuicTrafficFixture(t, "127.0.0.1", "native")
	upstreamProfile := tuicTrafficFixture(t, "127.0.0.1", "quic")
	primary := profile["outbounds"].([]any)[0].(map[string]any)
	upstream := upstreamProfile["outbounds"].([]any)[0].(map[string]any)
	upstream["tag"] = "upstream"
	primary["streamSettings"].(map[string]any)["sockopt"] = map[string]any{"dialerProxy": "upstream"}
	profile["outbounds"] = []any{primary, upstream}
	profile["stats"] = map[string]any{}
	profile["policy"] = map[string]any{"system": map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true}}
	client, stop := startTrafficCore(t, profile)
	for _, network := range []string{"tcp", "udp"} {
		trafficRoundTrip(t, client, network, "127.0.0.1")
	}
	manager := client.GetFeature(stats.ManagerType()).(stats.Manager)
	for _, tag := range []string{"proxy", "upstream"} {
		counter := manager.GetCounter("outbound>>>" + tag + ">>>traffic>>>uplink")
		if counter == nil || counter.Value() == 0 {
			t.Fatalf("TUIC chain bypassed %s", tag)
		}
	}
	stop()
	// Failure of a configured UDP hop must never reopen the physical TUIC socket directly.
	upstream["settings"].(map[string]any)["password"] = "incorrect-upstream-password"
	client, stop = startTrafficCore(t, profile)
	defer stop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	reached := make(chan struct{}, 1)
	go func() {
		peer, err := listener.Accept()
		if err != nil {
			return
		}
		defer peer.Close()
		reached <- struct{}{}
		peer.SetDeadline(time.Now().Add(2 * time.Second))
		io.Copy(peer, peer)
	}()
	conn, err := core.Dial(ctx, client, xnet.DestinationFromAddr(listener.Addr()))
	if err != nil {
		return
	}
	defer conn.Close()
	end := context.AfterFunc(ctx, func() { conn.Close() })
	defer end()
	conn.Write([]byte("failed-chain"))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("failed TUIC upstream produced traffic")
	}
	select {
	case <-reached:
		t.Fatal("failed TUIC upstream fell back to a direct socket")
	default:
	}
}

func tuicTrafficFixture(t *testing.T, host, mode string, expiry ...time.Time) map[string]any {
	t.Helper()
	notAfter := time.Now().Add(time.Hour)
	if len(expiry) != 0 {
		notAfter = expiry[0]
	}
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.CreateCertificate(rand.Reader, &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "tuic-fixture.example"},
		DNSNames: []string{"tuic-fixture.example"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: notAfter,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true},
		&x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "tuic-fixture.example"}, IsCA: true, BasicConstraintsValid: true}, pub, private)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})
	port := trafficPort(t, host)
	if binary := os.Getenv("ELARNI_TUIC_SERVER"); binary != "" {
		dir := t.TempDir()
		config := map[string]any{"log": map[string]any{"level": "info"}, "dns": map[string]any{"servers": []any{map[string]any{"type": "hosts", "predefined": map[string]any{"localhost": []string{"127.0.0.1"}}}}}, "inbounds": []any{map[string]any{"type": "tuic", "listen": host, "listen_port": port,
			"users": []any{map[string]any{"uuid": tuicFixtureUUID, "password": tuicFixturePassword}}, "auth_timeout": "500ms",
			"tls": map[string]any{"enabled": true, "alpn": []string{"h3"}, "certificate": strings.Split(string(certPEM), "\n"), "key": strings.Split(string(keyPEM), "\n")}}},
			"outbounds": []any{map[string]any{"type": "direct"}}}
		kind, ready := "sing-box", "sing-box started"
		var readiness func() bool
		arguments := []string{"run", "-c", filepath.Join(dir, "server.json")}
		if os.Getenv("ELARNI_TUIC_SERVER_KIND") == "mihomo" {
			kind, ready = "mihomo", "Tuic proxy listening"
			certPath, keyPath := filepath.Join(dir, "certificate.pem"), filepath.Join(dir, "key.pem")
			if err := os.WriteFile(certPath, certPEM, 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
				t.Fatal(err)
			}
			// Mihomo opens listeners while its dispatcher is still suspended. A
			// real proxy round trip is the readiness boundary, not that log line.
			peer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "tuic-peer-ready") }))
			t.Cleanup(peer.Close)
			proxyPort := trafficPort(t, "127.0.0.1")
			proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", proxyPort))
			transport := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
			t.Cleanup(transport.CloseIdleConnections)
			httpClient := &http.Client{Transport: transport, Timeout: 200 * time.Millisecond}
			readiness = func() bool {
				response, err := httpClient.Get(peer.URL)
				if err != nil {
					return false
				}
				defer response.Body.Close()
				body, err := io.ReadAll(response.Body)
				return err == nil && response.StatusCode == 200 && string(body) == "tuic-peer-ready"
			}
			config = map[string]any{"mode": "rule", "log-level": "info", "mixed-port": proxyPort, "bind-address": "127.0.0.1", "hosts": map[string]any{"localhost": "127.0.0.1"}, "rules": []string{"MATCH,DIRECT"},
				"tuic-server": map[string]any{"enable": true, "listen": net.JoinHostPort(host, fmt.Sprint(port)), "users": map[string]any{tuicFixtureUUID: tuicFixturePassword}, "certificate": certPath, "private-key": keyPath, "alpn": []string{"h3"}}}
			arguments = []string{"-d", dir, "-f", filepath.Join(dir, "server.json")}
		}
		raw, _ := json.Marshal(config)
		path := filepath.Join(dir, "server.json")
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
		command := exec.Command(binary, arguments...)
		output := &tuicFixtureLog{}
		command.Stdout, command.Stderr = output, output
		t.Cleanup(func() {
			if t.Failed() {
				log := output.String()
				if len(log) > 12000 {
					log = log[len(log)-12000:]
				}
				t.Log("synthetic server diagnostics: " + log)
			}
		})
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		ended := make(chan error, 1)
		go func() { ended <- command.Wait() }()
		t.Cleanup(func() {
			command.Process.Kill()
			select {
			case <-ended:
			case <-time.After(3 * time.Second):
				t.Error("TUIC fixture did not exit")
			}
		})
		deadline := time.Now().Add(5 * time.Second)
		for !strings.Contains(output.String(), ready) || (readiness != nil && !readiness()) {
			select {
			case err := <-ended:
				ended <- err
				t.Fatal("TUIC fixture startup failed")
			default:
			}
			if time.Now().After(deadline) {
				t.Fatal("TUIC fixture startup timeout")
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Log("server fixture: external " + kind)
	} else {
		pair, err := tls.X509KeyPair(certPEM, keyPEM)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		service, err := TUIC.NewService[int](TUIC.ServiceOptions{Context: ctx, Logger: logger.NOP(), TLSConfig: &tuicServerTLS{config: &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"h3"}}}, AuthTimeout: 500 * time.Millisecond, UDPTimeout: 5 * time.Second, Handler: tuicLoopbackHandler{}})
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		id := uuid.MustParse(tuicFixtureUUID)
		service.UpdateUsers([]int{1}, [][16]byte{id}, []string{tuicFixturePassword})
		socket, err := net.ListenPacket("udp", net.JoinHostPort(host, fmt.Sprint(port)))
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		if err := service.Start(socket); err != nil {
			cancel()
			socket.Close()
			t.Fatal(err)
		}
		t.Cleanup(func() { cancel(); service.Close(); socket.Close() })
		t.Log("server fixture: upstream TUIC service")
	}
	profile := map[string]any{"outbounds": []any{map[string]any{"protocol": "tuic", "tag": "proxy", "settings": map[string]any{"address": host, "port": port, "uuid": tuicFixtureUUID, "password": tuicFixturePassword, "udpRelayMode": mode},
		"streamSettings": map[string]any{"security": "tls", "tlsSettings": map[string]any{"serverName": "tuic-fixture.example", "alpn": []string{"h3"}, "disableSystemRoot": true,
			"certificates": []any{map[string]any{"usage": "verify", "certificate": strings.Split(string(certPEM), "\n")}}}}}}}
	raw, _ := json.Marshal(profile)
	imported, err := ImportClientProfiles(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
		t.Fatal(err)
	}
	profile["log"] = map[string]any{"loglevel": "none"}
	return profile
}

type tuicFixtureLog struct {
	mu sync.Mutex
	bytes.Buffer
}

func (b *tuicFixtureLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.Buffer.Write(p)
}
func (b *tuicFixtureLog) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.Buffer.String() }

type tuicServerTLS struct{ config *tls.Config }

func (c *tuicServerTLS) ServerName() string                 { return c.config.ServerName }
func (c *tuicServerTLS) SetServerName(n string)             { c.config.ServerName = n }
func (c *tuicServerTLS) NextProtos() []string               { return c.config.NextProtos }
func (c *tuicServerTLS) SetNextProtos(p []string)           { c.config.NextProtos = p }
func (*tuicServerTLS) HandshakeTimeout() time.Duration      { return time.Second }
func (*tuicServerTLS) SetHandshakeTimeout(time.Duration)    {}
func (c *tuicServerTLS) STDConfig() (*tls.Config, error)    { return c.config, nil }
func (c *tuicServerTLS) Client(n net.Conn) (ST.Conn, error) { return tls.Client(n, c.config), nil }
func (c *tuicServerTLS) Server(n net.Conn) (ST.Conn, error) { return tls.Server(n, c.config), nil }
func (c *tuicServerTLS) Clone() ST.Config                   { return &tuicServerTLS{config: c.config.Clone()} }
func (*tuicServerTLS) Start() error                         { return nil }
func (*tuicServerTLS) Close() error                         { return nil }

type tuicLoopbackHandler struct{}

func (tuicLoopbackHandler) NewConnectionEx(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer conn.Close()
	if onClose != nil {
		defer onClose(nil)
	}
	if !tuicLoopbackDestination(destination) {
		return
	}
	upstream, err := (&net.Dialer{}).DialContext(ctx, "tcp", destination.String())
	if err != nil {
		return
	}
	defer upstream.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close(); upstream.Close() })
	defer stop()
	done := make(chan struct{})
	go func() { io.Copy(upstream, conn); upstream.Close(); close(done) }()
	io.Copy(conn, upstream)
	conn.Close()
	<-done
}
func (tuicLoopbackHandler) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer conn.Close()
	if onClose != nil {
		defer onClose(nil)
	}
	upstream, err := net.ListenPacket("udp", "[::]:0")
	if err != nil {
		return
	}
	stop := context.AfterFunc(ctx, func() { conn.Close(); upstream.Close() })
	defer stop()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer conn.Close()
		data := make([]byte, 65535)
		for {
			n, peer, err := upstream.ReadFrom(data)
			if err != nil {
				return
			}
			if err := conn.WritePacket(sbuf.As(data[:n]), M.SocksaddrFromNet(peer)); err != nil {
				return
			}
		}
	}()
	defer func() { upstream.Close(); conn.Close(); <-done }()
	for {
		buffer := sbuf.NewSize(65535)
		target, err := conn.ReadPacket(buffer)
		if err != nil {
			buffer.Release()
			return
		}
		if !tuicLoopbackDestination(target) {
			buffer.Release()
			return
		}
		address := target.String()
		if target.Fqdn == "localhost" {
			address = net.JoinHostPort("127.0.0.1", fmt.Sprint(target.Port))
		}
		peer, err := net.ResolveUDPAddr("udp", address)
		if err == nil {
			_, err = upstream.WriteTo(buffer.Bytes(), peer)
		}
		buffer.Release()
		if err != nil {
			return
		}
	}
}
func tuicLoopbackDestination(destination M.Socksaddr) bool {
	return destination.Addr.IsLoopback() || destination.Fqdn == "localhost"
}
