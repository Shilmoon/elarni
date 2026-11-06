package main

import (
	"sync/atomic"
	"time"
)

// watchSocketPath turns route notifications and resumes from sleep into one
// moved call per burst, after the network settles: when the physical path read
// changed, or the system resumed (pooled connections may have died meanwhile).
func watchSocketPath[T comparable](wake <-chan struct{}, resumed *atomic.Bool, last T, settle time.Duration, read func() T, moved func()) {
	for range wake {
		time.Sleep(settle) // an adapter change or a resume arrives as a burst of notifications
		current := read()
		woke := resumed.Swap(false)
		if current != last || woke {
			last = current
			moved()
		}
	}
}

// resumeClock tells a resume from sleep: the time the system spent suspended
// grew between two checks. Wall clock steps do not count.
type resumeClock struct {
	suspended func() time.Duration
	last      time.Duration
}

func newResumeClock(suspended func() time.Duration) *resumeClock {
	return &resumeClock{suspended: suspended, last: suspended()}
}

func (c *resumeClock) resumed() bool {
	now := c.suspended()
	grew := now-c.last > 2*time.Second // far above Windows' 16 ms tick jitter; a shorter sleep ages nothing
	c.last = now
	return grew
}
