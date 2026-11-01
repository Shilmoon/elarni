package signal

import (
	"context"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
	"weak"
)

// Real TUN tests verify admission reuse. A fake clock makes exact deadline,
// timeout replacement, and concurrent/reentrant termination reproducible.
func TestActivityTimerDeadlines(t *testing.T) {
	t.Run("activity expires after the configured interval", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			var calls atomic.Int32
			timer := CancelAfterInactivity(context.Background(), func() { calls.Add(1) }, 10*time.Second)
			defer timer.SetTimeout(0)
			for range 4 {
				time.Sleep(6 * time.Second)
				timer.Update()
			}
			time.Sleep(9 * time.Second)
			synctest.Wait()
			if calls.Load() != 0 {
				t.Fatal("active association expired early")
			}
			time.Sleep(time.Second)
			synctest.Wait()
			if calls.Load() != 1 {
				t.Fatal("idle association retained beyond its configured deadline")
			}
		})
	})
	t.Run("replacement and concurrent close", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			var calls atomic.Int32
			var timer *ActivityTimer
			timer = CancelAfterInactivity(context.Background(), func() {
				calls.Add(1)
				timer.SetTimeout(0) // SOCKS Close reenters its own timer.
			}, 10*time.Second)
			time.Sleep(time.Second)
			timer.SetTimeout(20 * time.Second)
			time.Sleep(10 * time.Second)
			synctest.Wait()
			if calls.Load() != 0 {
				t.Fatal("replaced deadline still terminated the association")
			}
			timer.SetTimeout(2 * time.Second)
			time.Sleep(2 * time.Second)
			synctest.Wait()
			if calls.Load() != 1 {
				t.Fatal("shortened timeout did not terminate")
			}
			var group sync.WaitGroup
			for range 16 {
				group.Go(func() {
					timer.Update()
					timer.SetTimeout(time.Second)
					timer.SetTimeout(0)
				})
			}
			group.Wait()
			time.Sleep(30 * time.Second)
			synctest.Wait()
			if calls.Load() != 1 {
				t.Fatal("completed timer restarted or terminated twice")
			}
		})
	})
}

// A stopped runtime timer stays in its P's timer heap, closure included, until
// its old deadline, so the ActivityTimer it points to outlives the session. A
// consumed timer must not keep the session's cancel func, which reaches the
// session context and, through it, the stopped core.
func TestConsumedTimerReleasesItsSession(t *testing.T) {
	for name, end := range map[string]func(*ActivityTimer){
		"expired": func(timer *ActivityTimer) { timer.SetTimeout(time.Millisecond) },
		"closed":  func(timer *ActivityTimer) { timer.SetTimeout(0) },
	} {
		t.Run(name, func(t *testing.T) {
			timer, session, ended := startSession(time.Hour)
			end(timer)
			<-ended
			// The timer goroutine may still hold the callback while it returns.
			for deadline := time.Now().Add(time.Second); session.Value() != nil && time.Now().Before(deadline); {
				time.Sleep(10 * time.Millisecond)
				runtime.GC()
			}
			if session.Value() != nil {
				t.Fatal("a consumed timer keeps its session reachable")
			}
			runtime.KeepAlive(timer) // as the stopped hour timer in the runtime's heap does
		})
	}
}

func startSession(timeout time.Duration) (*ActivityTimer, weak.Pointer[[64]byte], chan struct{}) {
	session, ended := new([64]byte), make(chan struct{})
	timer := CancelAfterInactivity(context.Background(), func() { session[0] = 1; close(ended) }, timeout)
	return timer, weak.Make(session), ended
}
