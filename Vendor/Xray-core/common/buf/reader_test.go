package buf_test

import (
	"bytes"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
)

// A datagram larger than buf.Size stays one buffer of its exact length.
func TestPacketReaderKeepsWholeDatagram(t *testing.T) {
	mb, err := buf.NewPacketReader(bytes.NewReader(make([]byte, 20000))).ReadMultiBuffer()
	if err != nil || len(mb) != 1 || mb[0].Len() != 20000 {
		t.Fatalf("datagram split or truncated: %d buffers, %d bytes, %v", len(mb), mb.Len(), err)
	}
	buf.ReleaseMulti(mb)
}

type datagrams struct {
	reads [][]int32
	end   error
}

func (d *datagrams) ReadMultiBuffer() (buf.MultiBuffer, error) {
	if len(d.reads) == 0 {
		return nil, d.end
	}
	var mb buf.MultiBuffer
	for _, size := range d.reads[0] {
		b := buf.NewWithSize(size)
		b.Extend(size)
		mb = append(mb, b)
	}
	d.reads = d.reads[1:]
	if len(d.reads) == 0 {
		return mb, d.end
	}
	return mb, nil
}

type timeoutDatagrams struct{ *datagrams }

func (d timeoutDatagrams) ReadMultiBufferTimeout(time.Duration) (buf.MultiBuffer, error) {
	return d.ReadMultiBuffer()
}

// Oversized datagrams are dropped whole, never split, and never end the stream.
func TestPacketSizeLimitReaderDropsOversizedDatagrams(t *testing.T) {
	limited := buf.NewPacketSizeLimitReader(&datagrams{reads: [][]int32{{10, 9000, 5}, {9000}, {7}}, end: io.EOF}, buf.Size)
	var sizes []int32
	var err error
	for err == nil {
		var mb buf.MultiBuffer
		mb, err = limited.ReadMultiBuffer()
		for _, b := range mb {
			sizes = append(sizes, b.Len())
		}
		buf.ReleaseMulti(mb)
	}
	if err != io.EOF || len(sizes) != 3 || sizes[0] != 10 || sizes[1] != 5 || sizes[2] != 7 {
		t.Fatalf("kept %v, ended with %v", sizes, err)
	}
	limited = buf.NewPacketSizeLimitReader(&datagrams{reads: [][]int32{{9000}}, end: io.EOF}, buf.Size)
	if mb, err := limited.ReadMultiBuffer(); !mb.IsEmpty() || err != io.EOF {
		t.Fatalf("oversized final datagram: %d buffers, %v", len(mb), err)
	}
	// Timeout readers keep their capability; a dropped datagram reads as a timeout.
	timed, ok := buf.NewPacketSizeLimitReader(timeoutDatagrams{&datagrams{reads: [][]int32{{9000}, {3}}}}, buf.Size).(buf.TimeoutReader)
	if !ok {
		t.Fatal("timeout capability lost")
	}
	if mb, err := timed.ReadMultiBufferTimeout(time.Second); !mb.IsEmpty() || err != buf.ErrReadTimeout {
		t.Fatalf("dropped datagram: %d buffers, %v", len(mb), err)
	}
	if mb, _ := timed.ReadMultiBufferTimeout(time.Second); mb.Len() != 3 {
		t.Fatalf("next datagram lost: %d bytes", mb.Len())
	}
}

// Real sockets do not deterministically return their final bytes and error in
// the same read. Exercise that legal io.Reader boundary without network timing.
type finalRead struct {
	err   error
	reads int
}

func (r *finalRead) Read(p []byte) (int, error) {
	r.reads++
	if r.reads > 1 {
		return 0, io.EOF
	}
	return copy(p, "final bytes"), r.err
}

func TestBufferedReaderPreservesDataAndError(t *testing.T) {
	for _, terminal := range []error{io.EOF, errors.New("read failed after data")} {
		for _, mode := range []string{"read", "at-most", "mixed-multi", "mixed-write-to"} {
			t.Run(terminal.Error()+"/"+mode, func(t *testing.T) {
				source := &finalRead{err: terminal}
				r := &buf.BufferedReader{Reader: buf.NewReader(source)}
				var got bytes.Buffer
				var end error
				if mode == "read" {
					p := make([]byte, 2)
					for end == nil {
						var n int
						n, end = r.Read(p)
						got.Write(p[:n])
					}
				} else if mode == "at-most" {
					for end == nil {
						var mb buf.MultiBuffer
						mb, end = r.ReadAtMost(2)
						for _, b := range mb {
							got.Write(b.Bytes())
						}
						buf.ReleaseMulti(mb)
					}
				} else {
					p := make([]byte, 2)
					n, err := r.Read(p)
					got.Write(p[:n])
					if err != nil {
						t.Fatalf("error before final data was consumed: %v", err)
					}
					if mode == "mixed-multi" {
						for end == nil {
							var mb buf.MultiBuffer
							mb, end = r.ReadMultiBuffer()
							for _, b := range mb {
								got.Write(b.Bytes())
							}
							buf.ReleaseMulti(mb)
						}
					} else {
						n, err := r.WriteTo(&got)
						end = err
						if n != int64(len("final bytes")-2) {
							t.Errorf("WriteTo bytes = %d", n)
						}
					}
				}
				wantErr := terminal
				if mode == "mixed-write-to" && terminal == io.EOF {
					wantErr = nil
				}
				if got.String() != "final bytes" || end != wantErr || source.reads != 1 {
					t.Fatalf("got data %q, error %v, underlying reads %d; want final bytes, %v, one read", got.String(), end, source.reads, wantErr)
				}
			})
		}
	}
}
