package log // import "github.com/xtls/xray-core/common/log"

import (
	"sync/atomic"

	"github.com/xtls/xray-core/common/serial"
)

// Message is the interface for all log messages.
type Message interface {
	String() string
}

// Handler is the interface for log handler.
type Handler interface {
	Handle(msg Message)
}

// GeneralMessage is a general log message that can contain all kind of content.
type GeneralMessage struct {
	Severity Severity
	Content  interface{}
}

// String implements Message.
func (m *GeneralMessage) String() string {
	return serial.Concat("[", m.Severity, "] ", m.Content)
}

// Record writes a message into log stream.
func Record(msg Message) {
	if h := logHandler.Load(); h != nil {
		(*h).Handle(msg)
	}
	if tap := logTap.Load(); tap != nil {
		tap.record(msg)
	}
}

type SeverityLogger interface {
	Handler
	Severity() Severity
}

func GetSeverity() Severity {
	// log everything by default
	severity := Severity_Debug
	if h := logHandler.Load(); h != nil {
		if sh, ok := (*h).(SeverityLogger); ok {
			severity = sh.Severity()
		}
	}
	// The tap keeps its own filtered copy, so it must see every message its level keeps.
	if tap := logTap.Load(); tap != nil {
		severity = max(severity, tap.level())
	}
	return severity
}

var logHandler atomic.Pointer[Handler]

// The tap sees every message whatever handler the log config registered, so an
// embedding app can keep its own filtered copy while the core logs nothing.
var logTap atomic.Pointer[logTapEntry]

type logTapEntry struct {
	record func(Message)
	level  func() Severity
}

// SetTap sends every recorded message to tap as well; nil removes it. Messages above
// level() are not built unless the registered handler wants them.
func SetTap(tap func(Message), level func() Severity) {
	if tap == nil {
		logTap.Store(nil)
		return
	}
	logTap.Store(&logTapEntry{record: tap, level: level})
}

// RegisterHandler registers a new handler as current log handler. Previous registered handler will be discarded.
func RegisterHandler(handler Handler) {
	if handler == nil {
		panic("Log handler is nil")
	}
	logHandler.Store(&handler)
}
