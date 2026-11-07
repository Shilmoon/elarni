//go:build windows

package tun

import (
	"testing"

	"golang.zx2c4.com/wintun"
)

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
