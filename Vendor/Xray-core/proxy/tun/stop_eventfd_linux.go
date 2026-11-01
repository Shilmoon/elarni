package tun

import (
	"reflect"
	"sync"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// stopEventfdEndpoint closes the eventfd fdbased creates to stop each packet
// reader, which fdbased never closes.
type stopEventfdEndpoint struct {
	stack.LinkEndpoint
	once sync.Once
}

func (e *stopEventfdEndpoint) Wait() {
	e.LinkEndpoint.Wait()
	// The readers have exited, so nothing uses their eventfds any more.
	e.once.Do(func() {
		for _, fd := range stopEventfds(e.LinkEndpoint) {
			unix.Close(fd)
		}
	})
}

// shortcut: reads fdbased's unexported dispatchers by reflection; drop it once
// gVisor closes its own stop eventfds. TestHandlerCloseReleasesTheReaderStopEventfd
// fails if an upgrade moves them.
func stopEventfds(endpoint stack.LinkEndpoint) []int {
	value := reflect.ValueOf(endpoint)
	if value.Kind() != reflect.Pointer || value.Elem().Kind() != reflect.Struct {
		return nil
	}
	dispatchers := value.Elem().FieldByName("inboundDispatchers")
	if dispatchers.Kind() != reflect.Slice {
		return nil
	}
	var fds []int
	for i := range dispatchers.Len() {
		dispatcher := dispatchers.Index(i)
		for dispatcher.Kind() == reflect.Interface || dispatcher.Kind() == reflect.Pointer {
			dispatcher = dispatcher.Elem()
		}
		if dispatcher.Kind() != reflect.Struct {
			continue
		}
		if fd := dispatcher.FieldByName("EFD"); fd.Kind() == reflect.Int && fd.Int() >= 0 {
			fds = append(fds, int(fd.Int()))
		}
	}
	return fds
}
