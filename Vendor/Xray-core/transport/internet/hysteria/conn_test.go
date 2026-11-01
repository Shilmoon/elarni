package hysteria

import (
	"io"
	"sync"
	"testing"
)

func TestInterConnCloseRacesWrite(t *testing.T) {
	manager := &udpSessionManager{m: map[uint32]*InterConn{}}
	conn := &InterConn{id: 7, ch: make(chan []byte, 1), write: func([]byte) error { return nil }}
	conn.close = func() {
		manager.Lock()
		manager.close(conn)
		manager.Unlock()
	}
	manager.m[conn.id] = conn
	var group sync.WaitGroup
	for range 8 {
		group.Add(2)
		go func() { defer group.Done(); _ = conn.Close() }()
		go func() { defer group.Done(); _, _ = conn.Write(make([]byte, 8)) }()
	}
	group.Wait()
	if _, err := conn.Write(make([]byte, 8)); err != io.ErrClosedPipe {
		t.Fatalf("write after close: %v", err)
	}
	if _, err := conn.Read(make([]byte, 8)); err != io.EOF {
		t.Fatalf("read after close: %v", err)
	}
	if len(manager.m) != 0 {
		t.Fatal("closed session still registered")
	}
}
