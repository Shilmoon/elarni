package buf

import (
	"io"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
)

// readOneUDP reads one datagram into scratch and copies it into a buffer of
// its own size, so a queued small datagram does not pin a UDPSize allocation.
func readOneUDP(r io.Reader, scratch []byte) (*Buffer, error) {
	for i := 0; i < 64; i++ {
		n, err := r.Read(scratch)
		if n > 0 {
			b := NewWithSize(int32(n))
			b.Write(scratch[:n])
			return b, nil
		}
		if err != nil {
			return nil, err
		}
	}

	return nil, errors.New("Reader returns too many empty payloads.")
}

// ReadBuffer reads a Buffer from the given reader.
func ReadBuffer(r io.Reader) (*Buffer, error) {
	b := New()
	n, err := b.ReadFrom(r)
	if n > 0 {
		return b, err
	}
	b.Release()
	return nil, err
}

// BufferedReader is a Reader that keeps its internal buffer.
type BufferedReader struct {
	// Reader is the underlying reader to be read from
	Reader Reader
	// Buffer is the internal buffer to be read from first
	Buffer MultiBuffer
	// Splitter is a function to read bytes from MultiBuffer
	Splitter func(MultiBuffer, []byte) (MultiBuffer, int)
	readErr  error // Deliver a read error only after its buffered bytes.
}

// BufferedBytes returns the number of bytes that is cached in this reader.
func (r *BufferedReader) BufferedBytes() int32 {
	return r.Buffer.Len()
}

// ReadByte implements io.ByteReader.
func (r *BufferedReader) ReadByte() (byte, error) {
	var b [1]byte
	_, err := r.Read(b[:])
	return b[0], err
}

// Read implements io.Reader. It reads from internal buffer first (if available) and then reads from the underlying reader.
func (r *BufferedReader) Read(b []byte) (int, error) {
	spliter := r.Splitter
	if spliter == nil {
		spliter = SplitBytes
	}

	if !r.Buffer.IsEmpty() {
		buffer, nBytes := spliter(r.Buffer, b)
		r.Buffer = buffer
		if r.Buffer.IsEmpty() {
			r.Buffer = nil
		}
		return nBytes, nil
	}

	mb, err := r.ReadMultiBuffer()
	if mb.IsEmpty() && err != nil {
		return 0, err
	}
	r.readErr = err

	mb, nBytes := spliter(mb, b)
	if !mb.IsEmpty() {
		r.Buffer = mb
	}
	return nBytes, nil
}

// ReadMultiBuffer implements Reader.
func (r *BufferedReader) ReadMultiBuffer() (MultiBuffer, error) {
	if !r.Buffer.IsEmpty() || r.readErr != nil {
		mb := r.Buffer
		err := r.readErr
		r.Buffer = nil
		r.readErr = nil
		return mb, err
	}

	return r.Reader.ReadMultiBuffer()
}

// ReadAtMost returns a MultiBuffer with at most size.
func (r *BufferedReader) ReadAtMost(size int32) (MultiBuffer, error) {
	if r.Buffer.IsEmpty() {
		mb, err := r.ReadMultiBuffer()
		if mb.IsEmpty() && err != nil {
			return nil, err
		}
		r.Buffer = mb
		r.readErr = err
	}

	rb, mb := SplitSize(r.Buffer, size)
	r.Buffer = rb
	if r.Buffer.IsEmpty() {
		r.Buffer = nil
	}
	return mb, nil
}

func (r *BufferedReader) writeToInternal(writer io.Writer) (int64, error) {
	mbWriter := NewWriter(writer)
	var sc SizeCounter
	if r.Buffer != nil {
		sc.Size = int64(r.Buffer.Len())
		if err := mbWriter.WriteMultiBuffer(r.Buffer); err != nil {
			return 0, err
		}
		r.Buffer = nil
	}
	if r.readErr != nil {
		err := r.readErr
		r.readErr = nil
		return sc.Size, err
	}

	err := Copy(r.Reader, mbWriter, CountSize(&sc))
	return sc.Size, err
}

// WriteTo implements io.WriterTo.
func (r *BufferedReader) WriteTo(writer io.Writer) (int64, error) {
	nBytes, err := r.writeToInternal(writer)
	if errors.Cause(err) == io.EOF {
		return nBytes, nil
	}
	return nBytes, err
}

// Interrupt implements common.Interruptible.
func (r *BufferedReader) Interrupt() {
	common.Interrupt(r.Reader)
}

// Close implements io.Closer.
func (r *BufferedReader) Close() error {
	return common.Close(r.Reader)
}

// SingleReader is a Reader that read one Buffer every time.
type SingleReader struct {
	io.Reader
}

// ReadMultiBuffer implements Reader.
func (r *SingleReader) ReadMultiBuffer() (MultiBuffer, error) {
	b, err := ReadBuffer(r.Reader)
	return MultiBuffer{b}, err
}

// PacketSizeLimitReader drops datagrams longer than Limit.
type PacketSizeLimitReader struct {
	Reader
	Limit int32
}

// NewPacketSizeLimitReader keeps the TimeoutReader capability of reader.
func NewPacketSizeLimitReader(reader Reader, limit int32) Reader {
	limited := &PacketSizeLimitReader{Reader: reader, Limit: limit}
	if timeout, ok := reader.(TimeoutReader); ok {
		return &timeoutPacketSizeLimitReader{PacketSizeLimitReader: limited, timeout: timeout}
	}
	return limited
}

func (r *PacketSizeLimitReader) filter(mb MultiBuffer) MultiBuffer {
	kept := mb[:0]
	for _, b := range mb {
		if b.Len() > r.Limit {
			b.Release()
			continue
		}
		kept = append(kept, b)
	}
	return kept
}

// ReadMultiBuffer implements Reader.
func (r *PacketSizeLimitReader) ReadMultiBuffer() (MultiBuffer, error) {
	for {
		mb, err := r.Reader.ReadMultiBuffer()
		if mb = r.filter(mb); !mb.IsEmpty() || err != nil {
			return mb, err
		}
	}
}

type timeoutPacketSizeLimitReader struct {
	*PacketSizeLimitReader
	timeout TimeoutReader
}

// ReadMultiBufferTimeout implements TimeoutReader. A dropped datagram reads as a timeout.
func (r *timeoutPacketSizeLimitReader) ReadMultiBufferTimeout(d time.Duration) (MultiBuffer, error) {
	mb, err := r.timeout.ReadMultiBufferTimeout(d)
	if mb = r.filter(mb); mb.IsEmpty() && err == nil {
		return nil, ErrReadTimeout
	}
	return mb, err
}

// PacketReader is a Reader that read one Buffer every time.
type PacketReader struct {
	io.Reader
	scratch []byte
}

// ReadMultiBuffer implements Reader.
func (r *PacketReader) ReadMultiBuffer() (MultiBuffer, error) {
	if r.scratch == nil {
		r.scratch = make([]byte, UDPSize)
	}
	b, err := readOneUDP(r.Reader, r.scratch)
	if err != nil {
		return nil, err
	}
	return MultiBuffer{b}, nil
}
