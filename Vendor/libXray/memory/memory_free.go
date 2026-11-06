package memory

import (
	"runtime"
	"runtime/debug"
	"runtime/metrics"
	"time"
)

// idleRelease decides when a core has buffers to give back (Elarni): once traffic stops after a
// burst, or once connections close while traffic is idle.
type idleRelease struct {
	pending    bool
	burst      uint64 // allocated by the bursts since the last release
	ended      int    // goroutines that ended since then, busy checks included
	goroutines int
	last       time.Time
}

const (
	busyBytes        = 4 << 20 // allocated between two checks while traffic flows
	closedGoroutines = 16      // a few connections; short DNS and UDP sessions end with fewer
	// A release is two full collections; one due sooner waits, and runs once the core is idle.
	releaseGap = time.Minute
	// Unless this much was allocated or this many goroutines ended: waiting then held 100-250 MB
	// of a phone's memory for a minute.
	largeBurst = 64 << 20
	massClosed = 128
)

func (r *idleRelease) check(now time.Time, allocated uint64, goroutines int) bool {
	ended := r.goroutines - goroutines
	r.ended += max(0, ended)
	r.goroutines = goroutines
	if allocated >= busyBytes {
		r.pending = true
		r.burst += allocated
		return false
	}
	if !r.pending && ended < closedGoroutines {
		return false
	}
	if r.burst < largeBurst && r.ended < massClosed && now.Sub(r.last) < releaseGap {
		r.pending = true
		return false
	}
	r.pending, r.burst, r.ended, r.last = false, 0, 0, now
	return true
}

// releaseWhenIdle returns pooled buffers to the system when the core goes idle. Without a
// memory limit an idle Go process collects only every 2 minutes, and a sync.Pool keeps its
// buffers through one collection, so 150-340 MB stayed after a burst for minutes.
func releaseWhenIdle() {
	var r idleRelease
	var last uint64
	samples := []metrics.Sample{{Name: "/gc/heap/allocs:bytes"}, {Name: "/sched/goroutines:goroutines"}}
	for now := range time.Tick(5 * time.Second) {
		metrics.Read(samples)
		allocated := samples[0].Value.Uint64()
		if r.check(now, allocated-last, int(samples[1].Value.Uint64())) {
			runtime.GC() // moves pooled buffers to the victim cache; the next collection frees them
			debug.FreeOSMemory()
		}
		last = allocated
	}
}
