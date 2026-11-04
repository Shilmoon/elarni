package tun

import (
	"bytes"
	"io"
	"testing"

	"github.com/xtls/xray-core/common/buf"
)

// heldReader hands out at most one buffer's worth per Read, as gonet does for a full buffer,
// and blocks (fails the test) when asked for bytes it does not hold.
type heldReader struct {
	t    *testing.T
	data []byte
	eof  bool
}

func (r *heldReader) Read(p []byte) (int, error) {
	if len(r.data) == 0 {
		if r.eof {
			return 0, io.EOF
		}
		r.t.Fatal("read past the bytes the stack holds")
	}
	n := copy(p, r.data)
	r.data = r.data[n:]
	return n, nil
}

func (r *heldReader) ready() bool { return len(r.data) > 0 || r.eof }

// An upload read one 8 KiB buffer at a time reached the outbound as one write syscall per
// buffer: 43% of the core's CPU while a phone uploaded through the TUN.
func TestDrainReaderTakesEveryHeldBufferAtOnce(t *testing.T) {
	held := &heldReader{t: t, data: bytes.Repeat([]byte{1}, 3*buf.Size+100)}
	mb, err := (&drainReader{Reader: held, ready: held.ready}).ReadMultiBuffer()
	if err != nil {
		t.Fatal(err)
	}
	defer buf.ReleaseMulti(mb)
	if len(mb) != 4 || mb.Len() != 3*buf.Size+100 {
		t.Fatalf("one read returned %d bytes in %d buffers, want %d in 4", mb.Len(), len(mb), 3*buf.Size+100)
	}
}

func TestDrainReaderStopsAtEightBuffers(t *testing.T) {
	held := &heldReader{t: t, data: make([]byte, 10*buf.Size)}
	r := &drainReader{Reader: held, ready: held.ready}
	mb, _ := r.ReadMultiBuffer()
	if len(mb) != 8 {
		t.Fatalf("one read took %d buffers, want 8", len(mb))
	}
	buf.ReleaseMulti(mb)
	mb, _ = r.ReadMultiBuffer()
	if mb.Len() != 2*buf.Size {
		t.Fatalf("the next read returned %d bytes, want the remaining %d", mb.Len(), 2*buf.Size)
	}
	buf.ReleaseMulti(mb)
}

func TestDrainReaderReturnsDataBeforeEndOfStream(t *testing.T) {
	held := &heldReader{t: t, data: make([]byte, buf.Size+5), eof: true}
	r := &drainReader{Reader: held, ready: held.ready}
	mb, err := r.ReadMultiBuffer()
	if mb.Len() != buf.Size+5 {
		t.Fatalf("got %d bytes before the end of the stream, want %d (err %v)", mb.Len(), buf.Size+5, err)
	}
	buf.ReleaseMulti(mb)
	if mb, err = r.ReadMultiBuffer(); err != io.EOF || !mb.IsEmpty() {
		t.Fatalf("after the data: %d bytes, err %v, want io.EOF", mb.Len(), err)
	}
}
