//go:build darwin && !ios

package net_test

import (
	"context"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

func TestParentProcessSandboxHelper(t *testing.T) {
	parent := os.Getenv("ELARNI_SANDBOX_PARENT_PID")
	if parent == "" {
		return
	}
	process, ok := xnet.ParentProcess(os.Getpid())
	if !ok || strconv.Itoa(process.PID) != parent || process.Path != os.Getenv("ELARNI_SANDBOX_PARENT_PATH") {
		t.Fatalf("parent from the sandbox: %+v %v, want pid %s", process, ok, parent)
	}
}

// The packet tunnel extension is sandboxed too: "Include programs it starts" must read another
// program's parent from the App Sandbox.
func TestParentProcessFromAppSandbox(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	binary, executable := sandboxedTestBinary(t, ctx, "ParentFixture", "com.elarni.process-parent-checks")
	cmd := exec.CommandContext(ctx, binary, "-test.run=^TestParentProcessSandboxHelper$", "-test.v")
	cmd.Env = append(os.Environ(), "ELARNI_SANDBOX_PARENT_PID="+strconv.Itoa(os.Getpid()), "ELARNI_SANDBOX_PARENT_PATH="+executable)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("sandboxed parent lookup: %v\n%s", err, output)
	}
}
