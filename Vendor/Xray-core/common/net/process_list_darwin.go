//go:build darwin && !ios

package net

import (
	"path/filepath"

	"golang.org/x/sys/unix"
)

// ListProcesses lists the running programs, also from the App Sandbox.
func ListProcesses() ([]Process, error) {
	procs, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	var processes []Process
	for _, proc := range procs {
		pid := proc.Proc.P_pid
		if pid <= 0 {
			continue
		}
		path, err := darwinProcessPath(pid)
		if err != nil {
			continue // exited, or another user's process
		}
		path = filepath.ToSlash(path)
		processes = append(processes, Process{PID: int(pid), Name: filepath.Base(path), Path: path})
	}
	return processes, nil
}
