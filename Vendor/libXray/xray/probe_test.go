package xray

import (
	"context"
	"errors"
	"testing"
	"time"
)

// One failed close must not refuse every later server test.
func TestProbeCleanupHoldsNewProbesOnlyWhileItRuns(t *testing.T) {
	complete, _, pending := awaitProbeCleanup(context.Background(), func() error { return errors.New("close failed") }, func(context.Context) bool { return false })
	holdProbesUntilCleanup(complete, pending)
	if probeQuarantine.Load() != 0 {
		t.Fatal("a finished cleanup kept later probes out")
	}

	release := make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	complete, _, pending = awaitProbeCleanup(ctx, func() error { <-release; return errors.New("late failure") }, func(context.Context) bool { return true })
	holdProbesUntilCleanup(complete, pending)
	if complete || probeQuarantine.Load() != 1 {
		t.Fatal("a running cleanup admitted new probes")
	}
	close(release)
	for deadline := time.Now().Add(5 * time.Second); probeQuarantine.Load() != 0; time.Sleep(time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("a cleanup that ended with an error never released its hold")
		}
	}
}

func TestBusyProbeReportsItsOwnCode(t *testing.T) {
	probeQuarantine.Add(1)
	defer probeQuarantine.Add(-1)
	_, diagnostic, err := PingJSONWithPreparation(context.Background(), "{}", 1, "https://example.com/", "", "GET", "default", "", nil)
	if err == nil || err.Error() != "probe_busy" || diagnostic.Code != "probe_busy" {
		t.Fatalf("busy probe reported %v / %q", err, diagnostic.Code)
	}
}
