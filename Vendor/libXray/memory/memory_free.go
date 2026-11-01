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
