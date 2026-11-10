//go:build linux && !android

package net

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// A Flatpak app is named by its sandbox's /.flatpak-info, as xdg-desktop-portal names it. A
// runtime sandbox, another group's name, a link or a pipe in the process's root name no app.
func TestFlatpakAppReadsTheSandboxInfo(t *testing.T) {
	root := t.TempDir()
	previous := procRoot
	procRoot = root
	t.Cleanup(func() { procRoot = previous })
	sandbox := func(pid int) string {
		dir := filepath.Join(root, strconv.Itoa(pid), "root")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		return filepath.Join(dir, ".flatpak-info")
	}
	write := func(pid int, content string) {
		if err := os.WriteFile(sandbox(pid), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(10, "[Application]\nname=org.mozilla.firefox\nruntime=runtime/org.freedesktop.Platform/x86_64/24.08\n\n[Instance]\nname=other\n")
	write(11, "[Runtime]\nname=org.freedesktop.Sdk\n")
	write(12, "[Instance]\ninstance-id=1\n\n[Application]\n# comment\nruntime=x\n name = org.telegram.desktop \n")
	write(13, "[Application]\nname=../escape\n")
	if err := os.Symlink(sandbox(10), sandbox(14)); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(sandbox(15), 0o600); err != nil {
		t.Fatal(err)
	}
	for pid, want := range map[int]string{10: "org.mozilla.firefox", 11: "", 12: "org.telegram.desktop", 13: "", 14: "", 15: "", 16: ""} {
		done := make(chan string, 1)
		go func() { done <- FlatpakApp(pid) }()
		select {
		case got := <-done:
			if got != want {
				t.Errorf("pid %d: %q, want %q", pid, got, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("pid %d: reading the sandbox info blocked", pid)
		}
	}
}

// The test binary waits here when an identity test starts it as another program.
func TestHelperProcessWaits(t *testing.T) {
	if os.Getenv("ELARNI_IDENTITY_HELPER") != "1" {
		return
	}
	fmt.Println("ready")
	time.Sleep(30 * time.Second)
}

// An AppImage's programs run from its mount (APPDIR) and carry the image file (APPIMAGE); a
// program the app started from elsewhere keeps the variables but is not the app.
func TestAppImageOfARunningProgram(t *testing.T) {
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
	mount := filepath.Join(dir, ".mount_FixtureXy12")
	program := filepath.Join(mount, "usr", "bin", "fixture")
	if err := os.MkdirAll(filepath.Dir(program), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(program, binary, 0o700); err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(dir, "Fixture-1.2.3-x86_64.AppImage")
	// The kernel shows the new program's path before its environment, so wait until it runs.
	start := func(path string) int {
		command := exec.Command(path, "-test.run=^TestHelperProcessWaits$")
		command.Env = append(os.Environ(), "ELARNI_IDENTITY_HELPER=1", "APPIMAGE="+image, "APPDIR="+mount)
		output, err := command.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
		if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || line != "ready\n" {
			t.Fatalf("%s: %q %v", path, line, err)
		}
		if exe, err := getAbsPath(strconv.Itoa(command.Process.Pid)); err != nil || exe != path {
			t.Fatalf("%s runs as %q: %v", path, exe, err)
		}
		return command.Process.Pid
	}
	app := start(program)
	if got := AppImage(app, program); got != image {
		t.Fatalf("the app's program: %q, want %q", got, image)
	}
	if got := AppRule(app, filepath.Base(program), program); got != "appimage:"+image {
		t.Fatalf("the app's rule: %q", got)
	}
	started := start(self)
	if got := AppImage(started, self); got != "" {
		t.Fatalf("a program the app started: %q", got)
	}
	if got := AppRule(os.Getpid(), "test", self); got != "" {
		t.Fatalf("this test: %q", got)
	}
}
