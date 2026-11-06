package buf_test

import "syscall"

// processCPU returns the user and kernel CPU time the process has used, in nanoseconds.
func processCPU() int64 {
	var creation, exit, kernel, user syscall.Filetime
	process, _ := syscall.GetCurrentProcess()
	syscall.GetProcessTimes(process, &creation, &exit, &kernel, &user)
	ticks := func(t syscall.Filetime) int64 { return int64(t.HighDateTime)<<32 | int64(t.LowDateTime) }
	return (ticks(kernel) + ticks(user)) * 100
}
