package net

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Elarni: a burst of new connections each scanned the whole socket table at once. Waiters now share
// the next scan, but never one that started before they asked: their socket might be missing from it.
func TestProcessTableWaitersShareTheNextFetch(t *testing.T) {
	var fetches atomic.Int32
	release := make(chan struct{})
	started := make(chan struct{}, 8)
	f := &processTable{fetch: func(size uint32) ([]byte, error) {
		n := fetches.Add(1)
		started <- struct{}{}
		if n == 1 {
			<-release // the first scan is still running when the burst arrives
		}
		return []byte{byte(n)}, nil
	}}

	first := make(chan []byte)
	go func() {
		b, _ := f.get()
		first <- b
	}()
	<-started

	const burst = 20
	results := make(chan []byte, burst)
	var wg sync.WaitGroup
	for range burst {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b, err := f.get()
			if err != nil {
				t.Error(err)
			}
			results <- b
		}()
	}
	time.Sleep(50 * time.Millisecond) // let the burst queue behind the running scan
	close(release)
	if b := <-first; b[0] != 1 {
		t.Fatalf("first caller got scan %d", b[0])
	}
	wg.Wait()
	close(results)
	for b := range results {
		if b[0] != 2 {
			t.Fatalf("a waiter got scan %d, want the one that started after it asked (2)", b[0])
		}
	}
	if n := fetches.Load(); n != 2 {
		t.Fatalf("%d scans for 1 + %d callers, want 2", n, burst)
	}
}

func TestProcessTableSequentialCallersEachSeeAFreshFetch(t *testing.T) {
	var sizes []uint32
	n := 0
	f := &processTable{fetch: func(size uint32) ([]byte, error) {
		sizes = append(sizes, size)
		n++
		return make([]byte, 1000*n), nil
	}}
	for range 3 {
		if _, err := f.get(); err != nil {
			t.Fatal(err)
		}
	}
	if n != 3 {
		t.Fatalf("%d scans for 3 sequential lookups, want 3 (a socket opened in between must be found)", n)
	}
	// The next scan asks for the last size, so Windows fills the table once instead of twice.
	if sizes[0] != 0 || sizes[1] != 1000 || sizes[2] != 2000 {
		t.Fatalf("size hints %v, want [0 1000 2000]", sizes)
	}
}

func TestProcessTableErrorsReachTheirWaiters(t *testing.T) {
	fail := errors.New("scan failed")
	f := &processTable{fetch: func(uint32) ([]byte, error) { return nil, fail }}
	if _, err := f.get(); err != fail {
		t.Fatalf("err %v, want %v", err, fail)
	}
}
