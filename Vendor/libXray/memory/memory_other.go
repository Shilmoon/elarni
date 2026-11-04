//go:build !ios

package memory

import (
	"runtime"
	"runtime/debug"
	"runtime/metrics"
	"sync"
	"time"
)

var initForceFreeOnce sync.Once

// InitForceFree returns pooled buffers to the system when the core goes idle (Elarni). Without a
// memory limit an idle Go process collects only every 2 minutes, and a sync.Pool keeps its
// buffers through one collection, so 150-340 MB stayed after a burst for minutes.
func InitForceFree() {
	initForceFreeOnce.Do(func() {
		go func() {
			var r idleRelease
			var last uint64
			samples := []metrics.Sample{{Name: "/gc/heap/allocs:bytes"}, {Name: "/sched/goroutines:goroutines"}}
			for range time.Tick(5 * time.Second) {
				metrics.Read(samples)
				allocated := samples[0].Value.Uint64()
				if r.check(allocated-last, int(samples[1].Value.Uint64())) {
					runtime.GC() // moves pooled buffers to the victim cache; the next collection frees them
					debug.FreeOSMemory()
				}
				last = allocated
			}
		}()
	})
}
