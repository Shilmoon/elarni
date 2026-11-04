package memory

import "testing"

// Elarni: after a burst (40 stalled downloads over WireGuard or mKCP) the core kept 150-340 MB of
// pooled buffers for minutes: an idle Go process collects only every 2 minutes, and a sync.Pool
// empties on the second collection. The release runs once when traffic stops or connections
// close, never while busy, and not again while the core stays idle.
func TestIdleReleaseRunsOnceWhenABurstEnds(t *testing.T) {
	var r idleRelease
	steps := []struct {
		allocated  uint64 // bytes allocated since the previous check
		goroutines int
		release    bool
	}{
		{0, 40, false},          // idle from the start: nothing to give back
		{200 << 20, 200, false}, // busy
		{150 << 20, 200, false}, // still busy
		{1 << 20, 200, true},    // traffic stopped: release once
		{0, 200, false},         // still idle: no second collection
		{0, 195, false},         // a few short sessions ended
		{0, 60, true},           // the stalled connections closed and returned their buffers
		{0, 60, false},
		{20 << 20, 40, false}, // busy again; connections closing meanwhile change nothing
		{0, 40, true},         // and idle again
		{0, 40, false},
	}
	for i, s := range steps {
		if got := r.check(s.allocated, s.goroutines); got != s.release {
			t.Fatalf("step %d (%d bytes, %d goroutines): release %v, want %v", i, s.allocated, s.goroutines, got, s.release)
		}
	}
}
