//go:build linux

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The root supervisor must keep running the binary pkexec approved even when
// a same-user process replaces the file at its path (portable bundle in $HOME).
func TestPinnedExecutableSurvivesReplacement(t *testing.T) {
	run := "-test.run=^TestPinnedExecutableSurvivesReplacement$"
	switch os.Getenv("ELARNI_PIN_TEST") {
	case "print":
		fmt.Print("original")
		os.Exit(0)
	case "pin":
		file, path, err := pinnedLinuxExecutable()
		if err != nil {
			os.Exit(2)
		}
		defer file.Close()
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
		command := exec.Command(path, run)
		command.Env = append(os.Environ(), "ELARNI_PIN_TEST=print")
		output, _ := command.Output()
		os.Stdout.Write(output)
		os.Exit(0)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "elarni-core")
	if err := os.WriteFile(path, binary, 0o755); err != nil {
		t.Fatal(err)
	}
	child := exec.Command(path, run)
	child.Env = append(os.Environ(), "ELARNI_PIN_TEST=pin")
	input, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	child.Stdout = &output
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	replacement := path + ".new"
	if err := os.WriteFile(replacement, []byte("#!/bin/sh\necho replaced\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	input.Write([]byte("\n"))
	input.Close()
	if err := child.Wait(); err != nil {
		t.Fatal(err)
	}
	if output.String() != "original" {
		t.Fatalf("supervisor child ran %q, want the pinned original", output.String())
	}
}

// The root service and a desktop user's Connect must not run two tunnels: each
// tunnel's traffic matches the other's policy rule.
func TestLinuxVPNLockAdmitsOneTunnelPerMachine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "elarni-vpn.lock")
	first, err := acquireLinuxVPNLock(path)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := acquireLinuxVPNLock(path); err == nil || err.Error() != "vpn_guard_busy" {
		if second != nil {
			second.Close()
		}
		t.Fatalf("a second tunnel was admitted: %v", err)
	}
	first.Close()
	again, err := acquireLinuxVPNLock(path)
	if err != nil {
		t.Fatal("the lock outlived its tunnel", err)
	}
	again.Close()
}
