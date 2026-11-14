//go:build windows

package tun

import (
	"testing"
	"time"

	"golang.zx2c4.com/wintun"
)

// An adapter whose process was ended stays as a device that is gone, and creating one over it
// fails on Windows 10 after 15 s; open waits for Wintun's removal of it. Only such a leftover
// counts: no device at all, and a device that is there, do not hold a start up.
func TestOrphanedIsOnlyADeviceThatIsGone(t *testing.T) {
	for _, instance := range []string{
		`SWD\WINTUN\{00000000-0000-0000-0000-000000000000}`, // no such device
		`HTREE\ROOT\0`, // the root of the device tree, always present
		"",
	} {
		if orphaned(instance) {
			t.Errorf("%q counts as a leftover device", instance)
		}
	}
	if got, want := adapterInstance("elarni-tun-1"), `SWD\WINTUN\{B1FC6508-D4D3-2523-4B87-F70E40703D17}`; got != want {
		t.Errorf("the adapter's device is %s, want %s as Windows lists it", got, want)
	}
}

func TestAwaitRemovalWaitsForTheLeftoverAndGivesUp(t *testing.T) {
	asked := 0
	if !awaitRemoval(func() bool { asked++; return asked <= 3 }, time.Minute) || asked != 4 {
		t.Fatalf("asked %d times, want a return as soon as the leftover is gone", asked)
	}
	started := time.Now()
	if awaitRemoval(func() bool { return true }, 50*time.Millisecond) {
		t.Fatal("a leftover that stays counts as removed")
	}
	if waited := time.Since(started); waited < 50*time.Millisecond || waited > 5*time.Second {
		t.Fatalf("gave up after %v, want about the limit", waited)
	}
}

// A reconnect in the same helper must take the parked adapter, not create one.
func TestWindowsTunUnparkReusesTheParkedAdapter(t *testing.T) {
	kept := &wintun.Adapter{}
	parked.name, parked.adapter = "elarni-test", kept
	t.Cleanup(func() { parked.name, parked.adapter = "", nil })
	adapter, reused, err := unpark("elarni-test", "Elarni")
	if err != nil || adapter != kept || !reused {
		t.Fatalf("unpark = %p, %v, %v; want the parked adapter %p", adapter, reused, err, kept)
	}
	if parked.adapter != nil {
		t.Fatal("the adapter stayed parked while in use")
	}
}

func TestWindowsTunClosedOperationsDoNotUseNativeSession(t *testing.T) {
	device := &WindowsTun{closed: true}
	if _, err := device.ReadPacket(make([]byte, 1500)); err == nil {
		t.Fatal("closed read succeeded")
	}
	if err := device.WritePacket(nil, nil); err == nil {
		t.Fatal("closed write accepted")
	}
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
}
