//go:build windows

package main

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

// Uninstall must end the helper copies still running from the protected root
// before it clears their DNS guard and deletes the root, and must spare every
// program outside it, even one whose path shares the root's name.
func TestHelperUninstallStopsRunningCopiesThenRemovesTheRoot(t *testing.T) {
	if os.Getenv("ELARNI_HELPER_TEST") == "running" {
		_, _ = io.Copy(io.Discard, os.Stdin) // Runs until killed or its owner closes stdin.
		os.Exit(0)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	digest, err := fileDigest(self)
	if err != nil {
		t.Fatal(err)
	}
	// CI temp paths may use 8.3 names; Windows reports a process image by its long one.
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "Elarni VPN Helper")
	start := func(directory string) windows.Handle {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "elarni-core.exe")
		if _, err := copyHelperFile(self, path); err != nil {
			t.Fatal(err)
		}
		command := exec.Command(path, "-test.run=^TestHelperUninstallStopsRunningCopiesThenRemovesTheRoot$")
		command.Env = append(os.Environ(), "ELARNI_HELPER_TEST=running")
		input, err := command.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(command.Process.Pid))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			input.Close()
			_ = command.Wait()
			windows.CloseHandle(process)
		})
		return process
	}
	running := func(process windows.Handle) bool {
		state, err := windows.WaitForSingleObject(process, 0)
		return err == nil && state == uint32(windows.WAIT_TIMEOUT)
	}
	helper := start(helperDirectory(root, digest))
	other := start(root + " Tools")
	if err := os.WriteFile(filepath.Join(root, ".dns-guard"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	guardCleared, helperStopped := false, false
	err = uninstallHelper(root, func() error {
		guardCleared, helperStopped = true, !running(helper)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !guardCleared || !helperStopped {
		t.Fatalf("guard cleared %v, after the running helper stopped %v", guardCleared, helperStopped)
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("the helper root was kept:", err)
	}
	if !running(other) {
		t.Fatal("a program outside the helper root was stopped")
	}
}
