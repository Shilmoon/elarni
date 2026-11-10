//go:build linux && !android

package net

import (
	"path"
	"strconv"
	"strings"
)

// procStat reads a process's parent and start time (clock ticks after boot) from its stat line.
// The name field may hold spaces and parentheses, so the fields follow its last ")".
func procStat(pid int) (ppid int, started uint64, ok bool) {
	line := string(readProcFile(procRoot+"/"+strconv.Itoa(pid)+"/stat", 4096))
	end := strings.LastIndexByte(line, ')')
	if end < 0 {
		return 0, 0, false
	}
	fields := strings.Fields(line[end+1:])
	if len(fields) < 20 {
		return 0, 0, false
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, 0, false
	}
	started, err = strconv.ParseUint(fields[19], 10, 64)
	return ppid, started, err == nil
}

// parentPID returns the process that started pid. A parent that started after it holds a
// reused ID; init is no app's parent.
func parentPID(pid int) (int, bool) {
	ppid, started, ok := procStat(pid)
	if !ok || ppid <= 1 || ppid == pid {
		return 0, false
	}
	_, parentStarted, ok := procStat(ppid)
	if !ok || parentStarted > started {
		return 0, false
	}
	return ppid, true
}

// ParentProcess names the program that started a process, as FindProcess names programs.
func ParentProcess(pid int) (Process, bool) {
	ppid, ok := parentPID(pid)
	if !ok {
		return Process{}, false
	}
	exe, err := getAbsPath(strconv.Itoa(ppid))
	if err != nil || exe == "" {
		return Process{}, false
	}
	return Process{PID: ppid, Name: path.Base(exe), Path: exe}, true
}
