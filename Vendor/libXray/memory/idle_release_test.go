package memory

import (
	"slices"
	"testing"
	"time"
)

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
	start := time.Unix(1_700_000_000, 0)
	for i, s := range steps {
		// A minute apart, so the gap between releases never holds one back here.
		if got := r.check(start.Add(time.Duration(i)*time.Minute), s.allocated, s.goroutines); got != s.release {
			t.Fatalf("step %d (%d bytes, %d goroutines): release %v, want %v", i, s.allocated, s.goroutines, got, s.release)
		}
	}
}

// Idle flows time out in batches, which ended up as two full collections every 5 s. A release
// due within a minute of the last one waits for that minute, and still runs.
func TestIdleReleaseWaitsAMinuteBetweenReleases(t *testing.T) {
	var r idleRelease
	start := time.Unix(1_700_000_000, 0)
	var released []int
	for tick := 0; tick <= 30; tick++ { // the 5 s checks of 150 s
		allocated, goroutines := uint64(0), 200
		if tick >= 2 {
			goroutines = 150 // the burst's connections closed at 10 s
		}
		if tick == 0 {
			allocated = 200 << 20 // a burst
		}
		if tick == 14 {
			allocated = 20 << 20 // and a page load at 70 s
		}
		if r.check(start.Add(time.Duration(tick)*5*time.Second), allocated, goroutines) {
			released = append(released, tick)
		}
	}
	if want := []int{1, 13, 25}; !slices.Equal(released, want) {
		t.Fatalf("released at checks %v, want %v", released, want)
	}
}

// A phone kept 100-250 MB for up to a minute after 100 stalled downloads closed, because the
// release ran when they stalled. A large reclaim does not wait for the gap; small ones still do.
func TestIdleReleaseReturnsALargeReclaimAtOnce(t *testing.T) {
	var r idleRelease
	start := time.Unix(1_700_000_000, 0)
	var released []int
	for tick := 0; tick <= 20; tick++ { // the 5 s checks of 100 s
		allocated, goroutines := uint64(0), 400
		switch {
		case tick == 0:
			allocated = 300 << 20 // the downloads fill their buffers, then stall
		case tick >= 3 && tick < 5:
			goroutines = 100 // and close
		case tick == 5:
			goroutines, allocated = 100, 100<<20 // another download
		case tick >= 6:
			goroutines = 100
		}
		if tick >= 8 {
			goroutines = 80 // a few connections end
		}
		if r.check(start.Add(time.Duration(tick)*5*time.Second), allocated, goroutines) {
			released = append(released, tick)
		}
	}
	// The stall, the mass close, the download's end, then the few closes once a minute has passed.
	if want := []int{1, 3, 6, 18}; !slices.Equal(released, want) {
		t.Fatalf("released at checks %v, want %v", released, want)
	}
}

// Closing 100 stalled downloads can itself allocate past busyBytes; the closes still count once
// the core goes idle.
func TestIdleReleaseCountsClosesDuringABusyCheck(t *testing.T) {
	var r idleRelease
	start := time.Unix(1_700_000_000, 0)
	steps := []struct {
		allocated  uint64
		goroutines int
		release    bool
	}{
		{300 << 20, 400, false}, // the downloads fill their buffers
		{0, 400, true},          // and stall
		{10 << 20, 100, false},  // they close, and closing allocates
		{0, 100, true},          // idle: give their buffers back now, not a minute later
		{0, 100, false},
	}
	for i, s := range steps {
		if got := r.check(start.Add(time.Duration(i)*5*time.Second), s.allocated, s.goroutines); got != s.release {
			t.Fatalf("step %d: release %v, want %v", i, got, s.release)
		}
	}
}
