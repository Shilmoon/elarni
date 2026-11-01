package splithttp

import (
	"bytes"
	"testing"
)

// A post resent after an unanswered EOF can sit in the queue next to its first copy.
func TestUploadQueueDeliversAResentPostOnce(t *testing.T) {
	q := NewUploadQueue(30)
	post := append(bytes.Repeat([]byte{'a'}, 8<<10), bytes.Repeat([]byte{'b'}, 8<<10)...)
	q.Push(Packet{Seq: 1, Payload: post})
	q.Push(Packet{Seq: 1, Payload: post})
	q.Push(Packet{Seq: 0, Payload: []byte("z")})
	q.Push(Packet{Seq: 2, Payload: []byte("end")})
	var got []byte
	b := make([]byte, 8<<10)
	for !bytes.HasSuffix(got, []byte("end")) {
		n, err := q.Read(b)
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, b[:n]...)
	}
	if want := append(append([]byte("z"), post...), "end"...); !bytes.Equal(got, want) {
		t.Fatalf("read %d bytes, want %d", len(got), len(want))
	}
}
