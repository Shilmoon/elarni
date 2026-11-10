//go:build darwin && !ios

package net_test

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

func TestListProcessesSandboxHelper(t *testing.T) {
	parent := os.Getenv("ELARNI_SANDBOX_LIST_PARENT")
	if parent == "" {
		return
	}
	processes, err := xnet.ListProcesses()
	if err != nil {
		t.Fatal(err)
	}
	for _, process := range processes {
		if strconv.Itoa(process.PID) == parent && process.Path == os.Getenv("ELARNI_SANDBOX_LIST_PATH") {
			return
		}
	}
	t.Fatalf("the parent (pid %s) is not among %d listed processes", parent, len(processes))
}

// The macOS app is sandboxed, and its per-app editor counts running programs: the listing
// must see other processes with their paths from the App Sandbox.
func TestListProcessesFromAppSandbox(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	app := filepath.Join(root, "ListFixture.app")
	binary := filepath.Join(app, "Contents", "MacOS", "ListFixture")
	if err := os.MkdirAll(filepath.Dir(binary), 0o700); err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	output, err := os.OpenFile(binary, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o700)
	if err != nil {
		t.Fatal(err)
	}
	_, copyErr := io.Copy(output, source)
	if closeErr := output.Close(); copyErr != nil || closeErr != nil {
		t.Fatalf("copy test executable: %v %v", copyErr, closeErr)
	}
	info := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.elarni.process-list-checks</string><key>CFBundleExecutable</key><string>ListFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`
	if err := os.WriteFile(filepath.Join(app, "Contents", "Info.plist"), []byte(info), 0o600); err != nil {
		t.Fatal(err)
	}
	entitlements := filepath.Join(root, "sandbox.entitlements")
	if err := os.WriteFile(entitlements, []byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>`), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "codesign", "--force", "--sign", "-", "--entitlements", entitlements, app).CombinedOutput(); err != nil {
		t.Fatalf("sign sandbox fixture: %v\n%s", err, output)
	}
	cmd := exec.CommandContext(ctx, binary, "-test.run=^TestListProcessesSandboxHelper$", "-test.v")
	cmd.Env = append(os.Environ(), "ELARNI_SANDBOX_LIST_PARENT="+strconv.Itoa(os.Getpid()), "ELARNI_SANDBOX_LIST_PATH="+executable)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("sandboxed process listing: %v\n%s", err, output)
	}
}
