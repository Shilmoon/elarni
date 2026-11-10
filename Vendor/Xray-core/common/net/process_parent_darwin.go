//go:build darwin && !ios

package net

import (
	"path/filepath"

	"golang.org/x/sys/unix"
)

// ParentProcess names the program that started a process, as FindProcess names programs. A
// parent that started after it holds a reused ID; launchd is no app's parent.
func ParentProcess(pid int) (Process, bool) {
	child, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || child.Proc.P_pid != int32(pid) {
		return Process{}, false
	}
	ppid := child.Eproc.Ppid
	if ppid <= 1 || ppid == int32(pid) {
		return Process{}, false
	}
	parent, err := unix.SysctlKinfoProc("kern.proc.pid", int(ppid))
	if err != nil || parent.Proc.P_pid != ppid {
		return Process{}, false
	}
	started, parentStarted := child.Proc.P_starttime, parent.Proc.P_starttime
	if parentStarted.Sec > started.Sec || parentStarted.Sec == started.Sec && parentStarted.Usec > started.Usec {
		return Process{}, false
	}
	path, err := darwinProcessPath(ppid)
	if err != nil {
		return Process{}, false
	}
	path = filepath.ToSlash(path)
	return Process{PID: int(ppid), Name: filepath.Base(path), Path: path}, true
}
