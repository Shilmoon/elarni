package main

import (
	"slices"
	"testing"
	"time"
)

// scriptedAwake plays a timer whose waits end after the given awake time each:
// a wait that ends at resume from sleep has seen less awake time than it asked for.
type scriptedAwake struct {
	now    time.Duration
	steps  []time.Duration
	waited []time.Duration
}

func (s *scriptedAwake) clock() time.Duration { return s.now }

func (s *scriptedAwake) after(d time.Duration) <-chan time.Time {
	s.waited = append(s.waited, d)
	step := d
	if len(s.steps) > 0 {
		step, s.steps = s.steps[0], s.steps[1:]
	}
	s.now += step
	ready := make(chan time.Time, 1)
	ready <- time.Time{}
	return ready
}

func TestAwakeWaitWithoutSleepEndsAfterOneWait(t *testing.T) {
	s := &scriptedAwake{}
	awakeWait(30*time.Second, s.clock, s.after)
	if !slices.Equal(s.waited, []time.Duration{30 * time.Second}) || s.now != 30*time.Second {
		t.Fatalf("waits %v, awake %v", s.waited, s.now)
	}
}

func TestAwakeWaitThatStraddlesSleepWaitsForTheAwakeTimeLeft(t *testing.T) {
	// A connect started 5 s before a 12 h sleep: Windows ends the 30 s timer at
	// resume, with 5 s of awake time behind it.
	s := &scriptedAwake{steps: []time.Duration{5 * time.Second}}
	awakeWait(30*time.Second, s.clock, s.after)
	if !slices.Equal(s.waited, []time.Duration{30 * time.Second, 25 * time.Second}) || s.now != 30*time.Second {
		t.Fatalf("waits %v, awake %v", s.waited, s.now)
	}
}

func TestAwakeWaitOverSeveralSleepsCountsEachAwakePart(t *testing.T) {
	s := &scriptedAwake{steps: []time.Duration{2 * time.Second, 0, 10 * time.Second}}
	awakeWait(30*time.Second, s.clock, s.after)
	want := []time.Duration{30 * time.Second, 28 * time.Second, 28 * time.Second, 18 * time.Second}
	if !slices.Equal(s.waited, want) || s.now != 30*time.Second {
		t.Fatalf("waits %v, want %v, awake %v", s.waited, want, s.now)
	}
}

func TestAwakeAfterFiresOnThePlatformClock(t *testing.T) {
	start := time.Now()
	select {
	case <-awakeAfter(20 * time.Millisecond):
	case <-time.After(5 * time.Second):
		t.Fatal("awakeAfter did not fire")
	}
	if elapsed := time.Since(start); elapsed < 15*time.Millisecond {
		t.Fatalf("fired after %v", elapsed)
	}
}

func TestAwakeClockFollowsTimeWhileAwake(t *testing.T) {
	before, start := awakeClock(), time.Now()
	time.Sleep(200 * time.Millisecond)
	moved, elapsed := awakeClock()-before, time.Since(start)
	// The Windows sleep correction has tick-count granularity (about 16 ms).
	if moved < elapsed-50*time.Millisecond || moved > elapsed+50*time.Millisecond {
		t.Fatalf("awake clock moved %v in %v", moved, elapsed)
	}
}
