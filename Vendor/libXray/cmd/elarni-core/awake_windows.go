//go:build windows

package main

import "time"

// awakeClock is the time since start minus the time this boot spent asleep.
func awakeClock() time.Duration { return time.Since(awakeEpoch) - windowsSuspended() }
