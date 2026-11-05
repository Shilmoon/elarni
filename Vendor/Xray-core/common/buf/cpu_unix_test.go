//go:build unix

package buf_test

import "syscall"

// processCPU returns the user and system CPU time the process has used, in nanoseconds.
func processCPU() int64 {
	var usage syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &usage)
	return usage.Utime.Nano() + usage.Stime.Nano()
}
