//go:build ios

package memory

import (
	"runtime/debug"
	"sync"
	"time"
)

const (
	interval = 1
	// 30M
	maxMemory = 30 * 1024 * 1024
)

var initForceFreeOnce sync.Once

func forceFree(interval time.Duration) {
	go func() {
		var last uint64
		for {
			time.Sleep(interval)
			// A forced collection each second while the tunnel idles would only cost battery.
			releaseIfBusy(&last, 1024*1024, debug.FreeOSMemory)
		}
	}()
}

func InitForceFree() {
	initForceFreeOnce.Do(func() {
		debug.SetGCPercent(10)
		debug.SetMemoryLimit(maxMemory)
		duration := time.Duration(interval) * time.Second
		forceFree(duration)
	})
}
