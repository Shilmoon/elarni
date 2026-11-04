package wireguard

import (
	"net/netip"
	"testing"
	"time"
)

// gVisor's RACK loss detection compares send times against the RTT. Go's monotonic clock on
// Windows moves in 0.5-15.6 ms steps, so RTTs below a step read as zero and in-flight
// segments were declared lost: a WireGuard upload to a server under ~5 ms away resent most
// of its segments and ran at a fraction of the line rate.
func TestTunnelStackClockResolvesSubMillisecondRTTs(t *testing.T) {
	_, _, s, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.7.0.2")}, nil, 1420, false)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	clock := s.Clock()
	smallest := time.Hour
	last := clock.NowMonotonic()
	for end := time.Now().Add(100 * time.Millisecond); time.Now().Before(end); {
		now := clock.NowMonotonic()
		if step := now.Sub(last); step > 0 {
			smallest = min(smallest, step)
			last = now
		}
	}
	if smallest > 100*time.Microsecond {
		t.Fatalf("the tunnel stack's clock moves in %v steps", smallest)
	}
}
