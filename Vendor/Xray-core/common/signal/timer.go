package signal

import (
	"context"
	"sync"
	"time"
)

type ActivityUpdater interface {
	Update()
}

type ActivityTimer struct {
	mu         sync.Mutex
	timer      *time.Timer
	updatedAt  time.Time
	timeout    time.Duration
	generation uint64
	onTimeout  func()
	consumed   bool
}

func (t *ActivityTimer) Update() {
	t.mu.Lock()
	if !t.consumed {
		t.updatedAt = time.Now()
	}
	t.mu.Unlock()
}

func (t *ActivityTimer) check(generation uint64) {
	t.mu.Lock()
	if t.consumed || generation != t.generation {
		t.mu.Unlock()
		return
	}
	// Record activity without resetting the OS timer for every packet. At the
	// previous deadline, schedule only the remainder of the actual idle interval.
	if remaining := t.timeout - time.Since(t.updatedAt); remaining > 0 {
		t.timer = time.AfterFunc(remaining, func() { t.check(generation) })
		t.mu.Unlock()
		return
	}
	onTimeout := t.consume()
	t.mu.Unlock()
	onTimeout()
}

func (t *ActivityTimer) finish() {
	t.mu.Lock()
	if t.consumed {
		t.mu.Unlock()
		return
	}
	onTimeout := t.consume()
	if t.timer != nil {
		t.timer.Stop()
	}
	t.mu.Unlock()
	onTimeout()
}

// consume marks t done and hands over its callback. A stopped runtime timer
// stays in its P's timer heap, closure and t included, until its old deadline
// (up to the idle timeout) or a zombie sweep, so t must not keep the callback:
// it reaches the session context and, through it, the stopped core.
func (t *ActivityTimer) consume() func() {
	t.consumed = true
	onTimeout := t.onTimeout
	t.onTimeout = nil
	return onTimeout
}

func (t *ActivityTimer) SetTimeout(timeout time.Duration) {
	if timeout <= 0 {
		t.finish()
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	if t.consumed {
		return
	}
	if t.timer != nil {
		t.timer.Stop()
	}
	t.generation++
	generation := t.generation
	t.timeout = timeout
	t.updatedAt = time.Now()
	t.timer = time.AfterFunc(timeout, func() { t.check(generation) })
}

func CancelAfterInactivity(ctx context.Context, cancel context.CancelFunc, timeout time.Duration) *ActivityTimer {
	timer := &ActivityTimer{
		onTimeout: cancel,
	}
	timer.SetTimeout(timeout)
	return timer
}
