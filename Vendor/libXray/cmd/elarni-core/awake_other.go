//go:build !windows

package main

import "time"

// awakeClock is the time since start. CLOCK_MONOTONIC, which Go's monotonic
// time and timers use on Linux and Darwin, already stops while suspended.
func awakeClock() time.Duration { return time.Since(awakeEpoch) }
