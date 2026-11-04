package net

import "sync"

// processTable shares socket-table scans between concurrent process lookups (Elarni). A scan
// costs about 1.2 us per socket on Windows, and a burst of new connections made one each.
// A lookup only joins a scan that starts after it asked, so its own socket is in the result.
type processTable struct {
	fetch func(sizeHint uint32) ([]byte, error)

	mu      sync.Mutex
	next    *tableScan // waiting to start; every caller since the last start joins it
	running bool
	size    uint32 // length of the last table, so the next scan fills it in one call
}

type tableScan struct {
	done chan struct{}
	buf  []byte
	err  error
}

func (t *processTable) get() ([]byte, error) {
	t.mu.Lock()
	if t.next == nil {
		t.next = &tableScan{done: make(chan struct{})}
	}
	scan := t.next
	start := !t.running
	if start {
		t.running = true
	}
	t.mu.Unlock()
	if start {
		t.run()
	}
	<-scan.done
	return scan.buf, scan.err
}

// run performs the queued scan; a scan queued meanwhile runs on its own goroutine so this
// caller returns with its result.
func (t *processTable) run() {
	t.mu.Lock()
	scan, size := t.next, t.size
	t.next = nil
	t.mu.Unlock()

	scan.buf, scan.err = t.fetch(size)
	close(scan.done)

	t.mu.Lock()
	if scan.err == nil {
		t.size = uint32(len(scan.buf))
	}
	if t.next == nil {
		t.running = false
		t.mu.Unlock()
		return
	}
	t.mu.Unlock()
	go t.run()
}
