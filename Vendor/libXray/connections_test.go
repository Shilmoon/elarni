package libXray

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
)

func freeTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// The connections view names the app that per-app routing found and the outbound that took the
// connection, also when a per-app rule sends it through normal routing again.
func TestReadConnectionsNamesTheAppAndTheRoute(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			connection, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer connection.Close(); _, _ = io.Copy(connection, connection) }()
		}
	}()
	target := echo.Addr().(*net.TCPAddr).Port
	inbound := freeTCPPort(t)
	// The lookup matches the socket to the routed target, as a TUN flow's is: the inbound routes
	// to its own address, and the direct outbound dials the echo server instead.
	config := map[string]any{
		"inbounds": []any{map[string]any{"tag": "elarni-tun", "listen": "127.0.0.1", "port": inbound, "protocol": "dokodemo-door",
			"settings": map[string]any{"network": "tcp"}}},
		"outbounds": []any{
			map[string]any{"tag": "elarni-direct", "protocol": "freedom",
				"settings": map[string]any{"redirect": net.JoinHostPort("127.0.0.1", strconv.Itoa(target))}},
			map[string]any{"tag": "elarni-apps-0", "protocol": "loopback", "settings": map[string]any{"inboundTag": "elarni-apps-0"}},
			map[string]any{"tag": "elarni-block", "protocol": "blackhole"},
		},
		"routing": map[string]any{"rules": []any{
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "process": []string{executable},
				"outboundTag": "elarni-apps-0", "ruleTag": "elarni-per-app-listed"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "outboundTag": "elarni-block", "ruleTag": "elarni-per-app-other"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-apps-0"}, "outboundTag": "elarni-direct"},
		}},
	}
	raw, _ := json.Marshal(config)
	if err := xray.RunXrayFromJSON(string(raw)); err != nil {
		t.Fatal(err)
	}
	defer xray.StopXray()

	read := func(epoch int64, after uint64) xray.ConnectionsResult {
		t.Helper()
		var reply struct {
			Success bool                   `json:"success"`
			Data    xray.ConnectionsResult `json:"data"`
		}
		answer := Invoke(`{"apiVersion":1,"method":"readConnections","payload":{"epoch":` + strconv.FormatInt(epoch, 10) +
			`,"after":` + strconv.FormatUint(after, 10) + `}}`)
		if err := json.Unmarshal([]byte(answer), &reply); err != nil || !reply.Success {
			t.Fatalf("readConnections: %s", answer)
		}
		return reply.Data
	}
	empty := read(0, 0)
	if empty.Epoch == 0 || len(empty.Connections) != 0 {
		t.Fatalf("before any connection: %+v", empty)
	}

	client, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(inbound)), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := client.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	if reply := make([]byte, 4); func() error { _, err := io.ReadFull(client, reply); return err }() != nil || string(reply) != "ping" {
		t.Fatalf("the connection was not routed direct: %q", reply)
	}

	result := read(empty.Epoch, empty.Seq)
	if len(result.Connections) != 1 {
		t.Fatalf("connections %+v", result)
	}
	entry := result.Connections[0]
	if entry.Network != "tcp" || entry.Host != "127.0.0.1" || int(entry.Port) != inbound || entry.Inbound != "elarni-tun" ||
		entry.Outbound != "elarni-direct" || entry.Kind != "direct" || len(entry.Rules) != 1 || entry.Rules[0] != "elarni-per-app-listed" {
		t.Fatalf("entry %+v", entry)
	}
	path := entry.Path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	if entry.Owner != "found" || entry.PID != os.Getpid() || !samePath(path, executable) {
		t.Fatalf("owner %+v, want pid %d %s", entry, os.Getpid(), executable)
	}
	if later := read(result.Epoch, result.Seq); len(later.Connections) != 0 || later.Epoch != result.Epoch {
		t.Fatalf("unchanged list: %+v", later)
	}
	// A reader of an older core's list gets this core's list from the start.
	if again := read(result.Epoch-1, result.Seq); len(again.Connections) != 1 || again.Epoch != result.Epoch {
		t.Fatalf("another epoch: %+v", again)
	}
}

func samePath(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(filepath.Clean(filepath.FromSlash(a)), filepath.Clean(b))
	}
	return a == b
}

func TestReadConnectionsNeedsARunningCore(t *testing.T) {
	answer := Invoke(`{"apiVersion":1,"method":"readConnections","payload":{"epoch":0,"after":0}}`)
	if !json.Valid([]byte(answer)) || !containsFalse(answer) {
		t.Fatalf("readConnections without a core: %s", answer)
	}
}

func containsFalse(answer string) bool {
	var reply struct {
		Success bool `json:"success"`
	}
	return json.Unmarshal([]byte(answer), &reply) == nil && !reply.Success
}
