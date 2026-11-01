package encoding

import (
	"runtime"
	"runtime/debug"
	"runtime/metrics"
	"testing"

	"github.com/xtls/xray-core/common/buf"
)

// Protobuf allocates a fresh Hunk.Data for every received message.
type freshHunkConn struct{ HunkConn }

func (freshHunkConn) Recv() (*Hunk, error) { return &Hunk{Data: make([]byte, buf.Size)}, nil }

type freshMultiHunkConn struct{ MultiHunkConn }

func (freshMultiHunkConn) Recv() (*MultiHunk, error) {
	return &MultiHunk{Data: [][]byte{make([]byte, buf.Size), make([]byte, buf.Size)}}, nil
}

// Received payloads must not survive a GC. Wrapped hunks went into the shared buffer pool on
// release and nothing took them back out, so each GC kept the previous cycle's traffic alive and
// the heap goal grew for as long as a download ran (578-651 MB on gRPC against about 100 MB on
// VLESS-TCP on a Windows VM).
func TestReadMultiBufferDropsReceivedDataAtGC(t *testing.T) {
	for name, reader := range map[string]buf.Reader{
		"tun":   NewHunkReadWriter(freshHunkConn{}, nil),
		"multi": NewMultiHunkReadWriter(freshMultiHunkConn{}, nil),
	} {
		t.Run(name, func(t *testing.T) {
			defer debug.SetGCPercent(debug.SetGCPercent(-1)) // only the explicit GCs below
			live := []metrics.Sample{{Name: "/gc/heap/live:bytes"}}
			runtime.GC()
			metrics.Read(live)
			base := live[0].Value.Uint64()
			for round := 0; round < 3; round++ {
				for read := int32(0); read < 16<<20; {
					mb, err := reader.ReadMultiBuffer()
					if err != nil {
						t.Fatal(err)
					}
					read += mb.Len()
					buf.ReleaseMulti(mb)
				}
				runtime.GC()
				metrics.Read(live)
				if kept := int64(live[0].Value.Uint64()) - int64(base); kept > 2<<20 {
					t.Fatalf("round %d: %d KiB of 16 MiB received survived a GC", round, kept>>10)
				}
			}
		})
	}
}

func TestReadMultiBufferKeepsBytes(t *testing.T) {
	hunks := [][]byte{make([]byte, buf.Size+100), []byte("tail")}
	for i := range hunks[0] {
		hunks[0][i] = byte(i)
	}
	var want []byte
	for _, h := range hunks {
		want = append(want, h...)
	}
	single := &scriptedHunkConn{data: hunks}
	multi := &scriptedMultiHunkConn{data: [][][]byte{hunks}}
	for name, reader := range map[string]buf.Reader{
		"tun":   NewHunkReadWriter(single, nil),
		"multi": NewMultiHunkReadWriter(multi, nil),
	} {
		var got []byte
		for len(got) < len(want) {
			mb, err := reader.ReadMultiBuffer()
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			for _, b := range mb {
				got = append(got, b.Bytes()...)
			}
			buf.ReleaseMulti(mb)
		}
		if string(got) != string(want) {
			t.Fatalf("%s: payload changed", name)
		}
	}
}

type scriptedHunkConn struct {
	HunkConn
	data [][]byte
}

func (c *scriptedHunkConn) Recv() (*Hunk, error) {
	d := c.data[0]
	c.data = c.data[1:]
	return &Hunk{Data: d}, nil
}

type scriptedMultiHunkConn struct {
	MultiHunkConn
	data [][][]byte
}

func (c *scriptedMultiHunkConn) Recv() (*MultiHunk, error) {
	d := c.data[0]
	c.data = c.data[1:]
	return &MultiHunk{Data: d}, nil
}
