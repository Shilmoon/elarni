//go:build linux && !android

package net

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// The parent's ID and start time come from /proc/<pid>/stat, whose name field may hold spaces
// and parentheses. A parent that started after its child is a later program with a reused ID.
func TestParentIDFromProcStat(t *testing.T) {
	root := t.TempDir()
	previous := procRoot
	procRoot = root
	t.Cleanup(func() { procRoot = previous })
	stat := func(pid int, name string, ppid int, started int) {
		dir := filepath.Join(root, strconv.Itoa(pid))
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		line := strconv.Itoa(pid) + " (" + name + ") S " + strconv.Itoa(ppid) + " 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 " +
			strconv.Itoa(started) + " 0 0\n"
		if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(line), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	stat(30, "web (content) 2", 20, 500)
	stat(20, "browser", 10, 400)
	stat(10, "late", 1, 600)
	stat(40, "orphan", 1, 700)
	for pid, want := range map[int]int{30: 20, 20: 0, 40: 0, 50: 0} {
		got, ok := parentPID(pid)
		if want == 0 && ok || want != 0 && (!ok || got != want) {
			t.Errorf("parent of %d: %d %v, want %d", pid, got, ok, want)
		}
	}
}
