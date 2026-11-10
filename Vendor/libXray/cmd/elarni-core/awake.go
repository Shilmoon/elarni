package main

import "time"

var awakeEpoch = time.Now()

// awakeAfter is time.After counting only the time the machine was awake. Go's
// timers on Windows count sleep and hibernation, so a 30 s startup wait that
// straddled a sleep fired at resume while the core it waited for came up
// seconds later, and the helper exited.
func awakeAfter(d time.Duration) <-chan struct{} {
	fired := make(chan struct{})
	go func() {
		awakeWait(d, awakeClock, time.After)
		close(fired)
	}()
	return fired
}

// awakeWait returns once clock, which leaves out suspended time, has moved d.
// A timer that ends early, at resume, is followed by one for the awake time
// still missing.
func awakeWait(d time.Duration, clock func() time.Duration, after func(time.Duration) <-chan time.Time) {
	deadline := clock() + d
	for left := d; left > 0; left = deadline - clock() {
		<-after(left)
	}
}
