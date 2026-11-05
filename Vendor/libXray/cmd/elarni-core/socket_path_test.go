package main

import (
	"sync/atomic"
	"testing"
	"time"
)

// The C1 producer: one signal per burst, only when the physical path moved or the
// system resumed, since consumers verify every pooled connection on each signal.
func TestSocketPathSignalsOncePerMoveOrResume(t *testing.T) {
	for _, test := range []struct {
		name          string
		paths         []int // read after each settled wake
		resumeOnRead  int   // a resume noticed while this read settles (-1: none)
		notifications int   // queued before the watcher runs; the wake holds one
		moves         int
	}{
		{"unchanged path", []int{0}, -1, 1, 0},
		{"burst of notifications", []int{1}, -1, 5, 1},
		{"moved then settled", []int{1, 1}, -1, 2, 1},
		{"moved and back", []int{1, 0}, -1, 2, 2},
		{"resume on an unchanged path", []int{0}, 0, 1, 1},
		{"resume and a move together", []int{1}, 0, 1, 1},
		{"resume is reported once", []int{0, 0}, 0, 2, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			wake := make(chan struct{}, len(test.paths))
			for range test.notifications {
				select {
				case wake <- struct{}{}:
				default:
				}
			}
			if test.notifications > len(test.paths) && len(wake) != len(test.paths) {
				t.Fatal("the fixture queued the wrong number of wakes")
			}
			close(wake)
			var resumed atomic.Bool
			reads, moves := 0, 0
			watchSocketPath(wake, &resumed, 0, time.Millisecond, func() int {
				if reads == test.resumeOnRead {
					resumed.Store(true)
				}
				reads++
				return test.paths[reads-1]
			}, func() { moves++ })
			if reads != len(test.paths) || moves != test.moves {
				t.Fatalf("%d reads and %d moves, want %d and %d", reads, moves, len(test.paths), test.moves)
			}
			if resumed.Load() {
				t.Fatal("a reported resume stayed pending")
			}
		})
	}
}

func TestResumeClockCountsOnlyTimeSpentSuspended(t *testing.T) {
	suspended := time.Duration(0)
	clock := newResumeClock(func() time.Duration { return suspended })
	for _, step := range []struct {
		grew    time.Duration
		resumed bool
	}{
		{0, false},
		{16 * time.Millisecond, false}, // tick jitter
		{2 * time.Second, false},
		{30 * time.Second, true},
		{0, false}, // reported once
		{time.Hour, true},
	} {
		suspended += step.grew
		if clock.resumed() != step.resumed {
			t.Fatalf("after %v more suspended time, resumed is not %v", step.grew, step.resumed)
		}
	}
}
