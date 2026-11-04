package wireguard

import (
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"gvisor.dev/gvisor/pkg/tcpip"
)

var (
	queryPerformanceCounter   = windows.NewLazySystemDLL("kernel32.dll").NewProc("QueryPerformanceCounter")
	queryPerformanceFrequency = windows.NewLazySystemDLL("kernel32.dll").NewProc("QueryPerformanceFrequency")
)

// performanceClock reads the monotonic time from the performance counter. Go's own
// monotonic clock on Windows advances only with the system timer tick (0.5-15.6 ms), so
// gVisor measured short RTTs as zero and its RACK loss detection resent in-flight segments.
type performanceClock struct {
	tcpip.Clock
	frequency, base int64
}

func counter() int64 {
	var ticks int64
	queryPerformanceCounter.Call(uintptr(unsafe.Pointer(&ticks)))
	return ticks
}

func (c *performanceClock) NowMonotonic() tcpip.MonotonicTime {
	ticks := counter() - c.base
	elapsed := time.Duration(ticks/c.frequency)*time.Second + time.Duration(ticks%c.frequency*int64(time.Second)/c.frequency)
	return tcpip.MonotonicTime{}.Add(elapsed)
}

// tunnelClock returns the clock for the tunnel's TCP/IP stack; nil keeps gVisor's default.
func tunnelClock() tcpip.Clock {
	var frequency int64
	if ok, _, _ := queryPerformanceFrequency.Call(uintptr(unsafe.Pointer(&frequency))); ok == 0 || frequency <= 0 {
		return nil
	}
	return &performanceClock{Clock: tcpip.NewStdClock(), frequency: frequency, base: counter()}
}
