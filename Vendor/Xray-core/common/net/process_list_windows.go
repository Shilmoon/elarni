//go:build windows

package net

import (
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ListProcesses lists the running programs. A protected process's path cannot be read, so it
// is listed by name only.
func ListProcesses() ([]Process, error) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	var processes []Process
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		if entry.ProcessID == 0 {
			continue
		}
		name := strings.TrimSuffix(windows.UTF16ToString(entry.ExeFile[:]), ".exe")
		path, pathErr := getExecPathFromPID(entry.ProcessID)
		if pathErr == nil {
			path = filepath.ToSlash(path)
			name = strings.TrimSuffix(filepath.Base(path), ".exe")
		}
		processes = append(processes, Process{PID: int(entry.ProcessID), Name: name, Path: path})
	}
	if err != windows.ERROR_NO_MORE_FILES {
		return nil, err
	}
	return processes, nil
}
