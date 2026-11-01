package share

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"maps"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cloudflare/circl/sign/mldsa/mldsa65"
)

// serverCore is an upstream server binary that scripts/check-server-cores downloaded.
type serverCore struct {
	Name string            `json:"name"`
	Path string            `json:"path"`
	Env  map[string]string `json:"env"`
}

type lockedBuffer struct {
	sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	return b.buffer.Write(p)
}

func (b *lockedBuffer) String() string {
	b.Lock()
	defer b.Unlock()
	return b.buffer.String()
}

// startServerCore runs an upstream core with one inbound until the test ends.
func startServerCore(t *testing.T, server serverCore, inbound map[string]any) {
	t.Helper()
	config, err := json.Marshal(map[string]any{
		"log":      map[string]any{"loglevel": "warning"},
		"inbounds": []any{inbound},
		"outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{
			"finalRules": []any{map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "server.json")
	if err := os.WriteFile(path, config, 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(server.Path, "run", "-c", path)
	command.Env = os.Environ()
	for key, value := range server.Env {
		command.Env = append(command.Env, key+"="+value)
	}
	output := &lockedBuffer{}
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() {
		command.Wait()
		close(exited)
	}()
	t.Cleanup(func() {
		command.Process.Kill()
		<-exited
		if t.Failed() {
			t.Logf("%s output:\n%s", server.Name, output)
		}
	})
	// Xray logs "Xray <version> started" at warning level once every inbound listens.
	for deadline := time.Now().Add(15 * time.Second); !strings.Contains(output.String(), " started"); time.Sleep(20 * time.Millisecond) {
		select {
		case <-exited:
			t.Fatalf("%s exited before it started", server.Name)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not start", server.Name)
		}
	}
}

// TestImportedClientsReachUpstreamServerCores is the Go half of the release gate:
// clients imported from what a subscription hands out reach the newest upstream
// server cores, which scripts/check-server-cores lists in ELARNI_SERVER_CORES.
func TestImportedClientsReachUpstreamServerCores(t *testing.T) {
	raw := os.Getenv("ELARNI_SERVER_CORES")
	if raw == "" {
		t.Skip("scripts/check-server-cores supplies the server cores")
	}
	var cores []serverCore
	if err := json.Unmarshal([]byte(raw), &cores); err != nil || len(cores) == 0 {
		t.Fatalf("ELARNI_SERVER_CORES %q: %v", raw, err)
	}
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	const password = "fixture-password"
	serverTLS, clientTLS := trafficTLS(t)
	pin := clientTLS["tlsSettings"].(object)["pinnedPeerCertSha256"].(string)
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encode := base64.RawURLEncoding.EncodeToString
	seed := [32]byte{1}
	verification, _ := mldsa65.NewKeyFromSeed(&seed)
	// An external REALITY server probes its target with two dials per ALPN at start
	// and holds clients that arrive earlier for 5 s. The probes read until the target
	// closes, so a short read timeout ends them; count them to know they are done.
	target := realityCoverTarget(t)
	target.Config.ReadTimeout = time.Second
	var closed atomic.Int64
	target.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateClosed {
			closed.Add(1)
		}
	}
	target.StartTLS()
	t.Cleanup(target.Close)

	tlsStream := func(network string, extra object) object {
		stream := object{"network": network}
		maps.Copy(stream, serverTLS)
		maps.Copy(stream, extra)
		return stream
	}
	inbound := func(protocol string, settings, stream object) func(int) object {
		return func(port int) object {
			return object{"listen": "127.0.0.1", "port": port, "protocol": protocol, "settings": settings, "streamSettings": stream}
		}
	}
	vless := func(user object, decryption string, stream object) func(int) object {
		return inbound("vless", object{"clients": []any{user}, "decryption": decryption}, stream)
	}
	outbounds := func(protocol string, settings object, stream object) func(int) string {
		return func(port int) string {
			settings := maps.Clone(settings)
			settings["address"], settings["port"] = "127.0.0.1", port
			raw, _ := json.Marshal(object{"outbounds": []any{object{"protocol": protocol, "settings": settings, "streamSettings": stream}}})
			return string(raw)
		}
	}
	link := func(format string, args ...any) func(int) string {
		return func(port int) string { return fmt.Sprintf(format, append([]any{port}, args...)...) }
	}
	ss2022 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16))
	obfs := object{"udp": []any{object{"type": "salamander", "settings": object{"password": "fixture-obfs"}}}}
	cases := []struct {
		name    string
		server  func(port int) object
		client  func(port int) string
		reality bool
	}{
		// pinnedPeerCertSha256 and verifyPeerCertByName replaced allowInsecure upstream.
		{"VLESS TLS pinned link", vless(object{"id": id}, "none", tlsStream("raw", nil)),
			link("vless://"+id+"@127.0.0.1:%d?encryption=none&security=tls&sni=example.com&pcs=%s&type=tcp#pinned", pin), false},
		{"VLESS TLS allowInsecure link", vless(object{"id": id}, "none", tlsStream("raw", nil)),
			link("vless://" + id + "@127.0.0.1:%d?encryption=none&security=tls&sni=example.com&allowInsecure=1&type=tcp#insecure"), false},
		{"VLESS XHTTP TLS pinned link", vless(object{"id": id}, "none", tlsStream("xhttp", object{"xhttpSettings": object{"path": "/fixture"}})),
			link("vless://"+id+"@127.0.0.1:%d?encryption=none&security=tls&sni=example.com&pcs=%s&type=xhttp&path=%%2Ffixture&mode=stream-up#xhttp", pin), false},
		// REALITY servers refuse a ClientHello without an X25519MLKEM768 key share.
		{"VLESS REALITY Vision link", vless(object{"id": id, "flow": "xtls-rprx-vision"}, "none", object{"network": "raw", "security": "reality", "realitySettings": object{
			"target": target.Listener.Addr().String(), "serverNames": []string{"example.com"}, "privateKey": encode(private.Bytes()),
			"shortIds": []string{"0123456789abcdef"}, "mldsa65Seed": encode(seed[:])}}),
			link("vless://"+id+"@127.0.0.1:%d?encryption=none&flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&pbk=%s&sid=0123456789abcdef&pqv=%s&type=tcp#reality",
				encode(private.PublicKey().Bytes()), encode(verification.Bytes())), true},
		{"VLESS ML-KEM encryption", vless(object{"id": id}, "mlkem768x25519plus.native.600s."+encode(private.Bytes()), object{"network": "raw"}),
			outbounds("vless", object{"id": id, "encryption": "mlkem768x25519plus.native.1rtt." + encode(private.PublicKey().Bytes())}, object{"network": "raw"}), false},
		{"Trojan TLS pinned link", inbound("trojan", object{"clients": []any{object{"password": password}}}, tlsStream("raw", nil)),
			link("trojan://"+password+"@127.0.0.1:%d?security=tls&sni=example.com&pcs=%s&type=tcp#trojan", pin), false},
		{"Shadowsocks 2022", inbound("shadowsocks", object{"method": "2022-blake3-aes-128-gcm", "password": ss2022, "network": "tcp,udp"}, object{"network": "raw"}),
			outbounds("shadowsocks", object{"method": "2022-blake3-aes-128-gcm", "password": ss2022}, object{"network": "raw"}), false},
		// The ports parameter now builds the udphop mask under salamander.
		{"Hysteria2 salamander hop link", inbound("hysteria", object{"version": 2, "clients": []any{object{"auth": password}}},
			tlsStream("hysteria", object{"hysteriaSettings": object{"version": 2}, "finalmask": obfs})),
			func(port int) string {
				return fmt.Sprintf("hysteria2://%s@127.0.0.1:%d?sni=example.com&pinSHA256=%s&obfs=salamander&obfs-password=fixture-obfs&ports=%d&hop-interval=5#hy2",
					password, port, pin, port)
			}, false},
	}
	for _, server := range cores {
		for _, fixture := range cases {
			t.Run(server.Name+"/"+fixture.name, func(t *testing.T) {
				port := trafficPort(t)
				probes := closed.Load()
				startServerCore(t, server, fixture.server(port))
				clientPort := port
				if fixture.reality {
					for deadline := time.Now().Add(15 * time.Second); closed.Load()-probes < 6; time.Sleep(20 * time.Millisecond) {
						if time.Now().After(deadline) {
							t.Fatalf("REALITY probed its target %d times, not 6", closed.Load()-probes)
						}
					}
					clientPort = mlkemOnlyGate(t, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
				}
				imported, err := ImportClientProfiles(fixture.client(clientPort))
				if err != nil {
					t.Fatal(err)
				}
				var profile object
				if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
					t.Fatal(err)
				}
				profile["log"] = object{"loglevel": "none"}
				client, _ := startTrafficCore(t, profile)
				for _, address := range []string{"127.0.0.1", "::1"} {
					trafficRoundTrip(t, client, "tcp", address)
					trafficRoundTrip(t, client, "udp", address)
				}
			})
		}
	}
}
