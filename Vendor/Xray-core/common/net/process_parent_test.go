//go:build (darwin && !ios) || windows || (linux && !android)

package net

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A parent test starts the test binary, which waits here.
func TestHelperParentWaits(t *testing.T) {
	if os.Getenv("ELARNI_PARENT_HELPER") != "1" {
		return
	}
	fmt.Println("ready")
	time.Sleep(30 * time.Second)
}

func sameProgram(a, b string) bool {
	if resolved, err := filepath.EvalSymlinks(a); err == nil {
		a = resolved
	}
	if resolved, err := filepath.EvalSymlinks(b); err == nil {
		b = resolved
	}
	a, b = filepath.Clean(filepath.FromSlash(a)), filepath.Clean(filepath.FromSlash(b))
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// "Include programs it starts" walks from a connection's program to the programs that started
// it: each parent is named as the lookup names programs.
func TestParentProcessOfARunningProgram(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(self, "-test.run=^TestHelperParentWaits$")
	command.Env = append(os.Environ(), "ELARNI_PARENT_HELPER=1")
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = command.Process.Kill(); _ = command.Wait() }()
	if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("helper: %q %v", line, err)
	}
	parent, ok := ParentProcess(command.Process.Pid)
	if !ok || parent.PID != os.Getpid() || !sameProgram(parent.Path, self) || parent.Name != filepath.Base(parent.Path) ||
		strings.Contains(parent.Path, `\`) {
		t.Fatalf("parent of the helper: %+v %v, want pid %d %s", parent, ok, os.Getpid(), self)
	}
	if grand, ok := ParentProcess(os.Getpid()); !ok || grand.PID != os.Getppid() {
		t.Fatalf("parent of this test: %+v %v, want pid %d", grand, ok, os.Getppid())
	}
	// A program that exited has no parent to name.
	if _, ok := ParentProcess(1 << 30); ok {
		t.Fatal("a missing program has a parent")
	}
}

// One level of a "children:" rule's walk: the program that started this test.
func BenchmarkParentProcess(b *testing.B) {
	for b.Loop() {
		if _, ok := ParentProcess(os.Getpid()); !ok {
			b.Fatal("no parent")
		}
	}
}
