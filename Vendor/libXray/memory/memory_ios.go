//go:build ios

package memory

import (
	"runtime/debug"
	"sync"
)

const (
	// 30M
	maxMemory = 30 * 1024 * 1024
)

var initForceFreeOnce sync.Once

// The limit already makes allocation return memory to the system; a forced release every second
// under load only cost CPU, so iOS releases when traffic stops, as the other platforms do (Elarni).
func InitForceFree() {
	initForceFreeOnce.Do(func() {
		debug.SetGCPercent(10)
		debug.SetMemoryLimit(maxMemory)
		go releaseWhenIdle()
	})
}
