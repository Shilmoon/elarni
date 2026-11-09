//go:build windows

package net

import (
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ParentProcess names the program that started a process, as FindProcess names programs.
// Windows keeps the creator's ID after it exits, so a parent must have started first: a later
// program may hold that ID now.
func ParentProcess(pid int) (Process, bool) {
	child, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return Process{}, false
	}
	defer windows.CloseHandle(child)
	var info windows.PROCESS_BASIC_INFORMATION
	if windows.NtQueryInformationProcess(child, windows.ProcessBasicInformation, unsafe.Pointer(&info),
		uint32(unsafe.Sizeof(info)), nil) != nil {
		return Process{}, false
	}
	ppid := uint32(info.InheritedFromUniqueProcessId)
	// 0 and 4 are the idle process and the kernel.
	if ppid == 0 || ppid == 4 || ppid == uint32(pid) {
		return Process{}, false
	}
	parent, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, ppid)
	if err != nil {
		return Process{}, false
	}
	defer windows.CloseHandle(parent)
	var childStarted, parentStarted, exited, kernel, user windows.Filetime
	if windows.GetProcessTimes(child, &childStarted, &exited, &kernel, &user) != nil ||
		windows.GetProcessTimes(parent, &parentStarted, &exited, &kernel, &user) != nil ||
		parentStarted.Nanoseconds() > childStarted.Nanoseconds() {
		return Process{}, false
	}
	path, err := getExecPathFromPID(ppid)
	if err != nil {
		return Process{}, false
	}
	path = filepath.ToSlash(path)
	return Process{PID: int(ppid), Name: filepath.Base(path), Path: path}, true
}
