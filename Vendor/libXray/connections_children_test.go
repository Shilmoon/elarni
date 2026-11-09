//go:build (darwin && !ios) || windows || (linux && !android)

package libXray

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
)

// A children test starts a copy of the test binary, another program, which connects here.
func TestHelperChildDials(t *testing.T) {
	address := os.Getenv("ELARNI_CHILD_DIALS")
	if address == "" {
		return
	}
	connection, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err == nil {
		_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
		_, err = connection.Write([]byte("ping"))
	}
	reply := make([]byte, 4)
	if err == nil {
		_, err = io.ReadFull(connection, reply)
	}
	fmt.Printf("%s %v\n", reply, err)
	time.Sleep(30 * time.Second)
}

// "children:<rule>" routes the programs a listed app starts, as Claude starts Claude Code, and
// the connections view names the app that started each.
func TestChildrenRuleRoutesTheProgramsAnAppStarts(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if resolved, err := filepath.EvalSymlinks(self); err == nil {
		self = resolved
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(dir); err == nil {
		dir = resolved
	}
	helper := filepath.Join(dir, "helper")
	if runtime.GOOS == "windows" {
		helper += ".exe"
	}
	if err := os.WriteFile(helper, binary, 0o700); err != nil {
		t.Fatal(err)
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
	inbound := freeTCPPort(t)
	config := map[string]any{
		"inbounds": []any{map[string]any{"tag": "elarni-tun", "listen": "127.0.0.1", "port": inbound, "protocol": "dokodemo-door",
			"settings": map[string]any{"network": "tcp"}}},
		"outbounds": []any{
			map[string]any{"tag": "elarni-direct", "protocol": "freedom",
				"settings": map[string]any{"redirect": echo.Addr().String()}},
			map[string]any{"tag": "elarni-apps-0", "protocol": "loopback", "settings": map[string]any{"inboundTag": "elarni-apps-0"}},
			map[string]any{"tag": "elarni-block", "protocol": "blackhole"},
		},
		"routing": map[string]any{"rules": []any{
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "process": []string{"children:" + self},
				"outboundTag": "elarni-apps-0", "ruleTag": "elarni-per-app-listed-0"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-tun"}, "outboundTag": "elarni-block", "ruleTag": "elarni-per-app-other"},
			map[string]any{"type": "field", "inboundTag": []string{"elarni-apps-0"}, "outboundTag": "elarni-direct"},
		}},
	}
	raw, _ := json.Marshal(config)
	if err := xray.RunXrayFromJSON(string(raw)); err != nil {
		t.Fatal(err)
	}
	defer xray.StopXray()
	before, err := xray.ReadConnections(0, 0)
	if err != nil {
		t.Fatal(err)
	}

	command := exec.Command(helper, "-test.run=^TestHelperChildDials$")
	command.Env = append(os.Environ(), "ELARNI_CHILD_DIALS=127.0.0.1:"+strconv.Itoa(inbound))
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = command.Process.Kill(); _ = command.Wait() }()
	// The block rule would close the connection unanswered.
	if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || line != "ping <nil>\n" {
		t.Fatalf("the started program was not routed by its parent's rule: %q %v", line, err)
	}
	result, err := xray.ReadConnections(before.Epoch, before.Seq)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Connections) != 1 {
		t.Fatalf("connections %+v", result)
	}
	entry := result.Connections[0]
	if entry.Owner != "found" || entry.PID != command.Process.Pid || !samePath(entry.Path, helper) || entry.Kind != "direct" ||
		len(entry.Rules) != 1 || entry.Rules[0] != "elarni-per-app-listed-0" || !samePath(entry.Via, self) {
		t.Fatalf("entry %+v, want %s started by %s", entry, helper, self)
	}
}
