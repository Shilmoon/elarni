package memory

import "runtime/metrics"

// releaseIfBusy calls free when the heap allocated threshold bytes since the last
// release or holds that much freed memory not yet returned to the system.
func releaseIfBusy(last *uint64, threshold uint64, free func()) bool {
	samples := []metrics.Sample{{Name: "/gc/heap/allocs:bytes"}, {Name: "/memory/classes/heap/free:bytes"}}
	metrics.Read(samples)
	allocated := samples[0].Value.Uint64()
	if allocated-*last < threshold && samples[1].Value.Uint64() < threshold {
		return false
	}
	free()
	*last = allocated
	return true
}

// idleRelease decides when a desktop or Android core has buffers to give back (Elarni): once
// traffic stops after a burst, or once connections close while traffic is idle.
type idleRelease struct {
	pending    bool
	goroutines int
}

const (
	busyBytes        = 4 << 20 // allocated between two checks while traffic flows
	closedGoroutines = 16      // a few connections; short DNS and UDP sessions end with fewer
)

func (r *idleRelease) check(allocated uint64, goroutines int) bool {
	closed := goroutines <= r.goroutines-closedGoroutines
	r.goroutines = goroutines
	if allocated >= busyBytes {
		r.pending = true
		return false
	}
	release := r.pending || closed
	r.pending = false
	return release
}
