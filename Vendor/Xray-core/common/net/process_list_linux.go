//go:build linux && !android

package net

import (
	"os"
	"path"
	"strconv"
)

// ListProcesses lists the running programs whose executable this process may read: all of
// them as root, otherwise the user's own.
func ListProcesses() ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	var processes []Process
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || !entry.IsDir() {
			continue
		}
		exe, err := getAbsPath(entry.Name())
		if err != nil || exe == "" {
			continue // a kernel thread, or another user's process
		}
		processes = append(processes, Process{PID: pid, Name: path.Base(exe), Path: exe})
	}
	return processes, nil
}
