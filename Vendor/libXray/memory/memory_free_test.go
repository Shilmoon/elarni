package memory

import (
	"runtime/debug"
	"testing"
)

var sink []byte

// An idle tunnel allocates next to nothing, so the once-a-second release must not force a collection then.
func TestReleaseRunsOnlyAfterTheHeapWasUsed(t *testing.T) {
	var last uint64
	frees := 0
	free := func() { frees++; debug.FreeOSMemory() }
	releaseIfBusy(&last, 1<<20, free)
	sink = make([]byte, 4<<20)
	if !releaseIfBusy(&last, 1<<20, free) {
		t.Fatal("4 MiB were allocated, but the memory was not released")
	}
	before := frees
	if releaseIfBusy(&last, 1<<20, free) || frees != before {
		t.Fatal("an idle heap was collected again")
	}
}
