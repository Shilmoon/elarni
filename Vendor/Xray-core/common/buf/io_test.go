package buf_test

import (
	"runtime"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
)

type readyReader struct{}

func (readyReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	b := buf.New()
	b.WriteString("x")
	return buf.MultiBuffer{b}, nil
}

// A read that returns before its timeout must not leave anything waiting out the timeout.
func TestTimeoutReadLeavesNoGoroutineBehind(t *testing.T) {
	reader := &buf.TimeoutWrapperReader{Reader: readyReader{}}
	before := runtime.NumGoroutine()
	for range 1000 {
		mb, err := reader.ReadMultiBufferTimeout(time.Hour)
		if err != nil || mb.Len() != 1 {
			t.Fatalf("read %d bytes, %v", mb.Len(), err)
		}
		buf.ReleaseMulti(mb)
	}
	// The reader goroutine of the last read may still be finishing.
	deadline := time.Now().Add(5 * time.Second)
	for runtime.NumGoroutine() > before+1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := runtime.NumGoroutine(); n > before+1 {
		t.Fatalf("%d goroutines left after 1000 reads (%d before)", n, before)
	}
}
