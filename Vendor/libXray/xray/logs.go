package xray

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/log"
)

// The core's log lines are redacted as they are recorded, so no reader, copy
// or export ever holds a key, host or address. Only memory keeps them.
type LogEntry struct {
	Seq   int64  `json:"seq"`
	Time  int64  `json:"time"`
	Level string `json:"level"`
	Text  string `json:"text"`
}

type LogsResult struct {
	Level   string     `json:"level"`
	Entries []LogEntry `json:"entries"`
	// Last is the newest seq; below a reader's cursor it means the ring restarted.
	Last int64 `json:"last"`
}

const (
	logCapacity = 1000
	maxLogText  = 1000
	// An outage logs a failed dial per attempt; past this, lines are counted instead of redacted.
	maxLogsPerSecond = 200
)

// Index is the severity; a message is kept when its severity is at most the level.
var logLevelNames = []string{"none", "error", "warning", "info", "debug"}

var (
	logLevel atomic.Int32
	logMu    sync.Mutex
	// Line seq sits at logRing[seq%logCapacity].
	logRing [logCapacity]LogEntry
	logNext int64
	// The lines kept in logSecond, and those dropped since the last kept one.
	logSecond, logInSecond, logDropped int64
	logNow                             = time.Now
)

func init() {
	resetLogs()
	log.SetTap(recordLog, func() log.Severity { return log.Severity(logLevel.Load()) })
}

func resetLogs() {
	logMu.Lock()
	defer logMu.Unlock()
	logLevel.Store(int32(log.Severity_Warning))
	logRing = [logCapacity]LogEntry{}
	logNext = 1
	logSecond, logInSecond, logDropped = 0, 0, 0
}

func LogLevel() string { return logLevelNames[logLevel.Load()] }

func SetLogLevel(name string) error {
	for index, known := range logLevelNames {
		if known == name {
			logLevel.Store(int32(index))
			return nil
		}
	}
	return errors.New("unknown log level")
}

// ReadLogs returns the kept lines after seq, oldest first.
func ReadLogs(after int64) LogsResult {
	logMu.Lock()
	defer logMu.Unlock()
	entries := []LogEntry{}
	for seq := max(after+1, logNext-logCapacity, 1); seq < logNext; seq++ {
		entries = append(entries, logRing[seq%logCapacity])
	}
	return LogsResult{Level: LogLevel(), Entries: entries, Last: logNext - 1}
}

// LastLogSeq is the newest line's seq, so a reader can skip the lines kept before it started.
func LastLogSeq() int64 {
	logMu.Lock()
	defer logMu.Unlock()
	return logNext - 1
}

// AppendLogs keeps lines another process already filtered and redacted, under this ring's numbering.
func AppendLogs(entries []LogEntry) {
	logMu.Lock()
	defer logMu.Unlock()
	for _, entry := range entries {
		appendLogLocked(entry)
	}
}

func appendLogLocked(entry LogEntry) {
	entry.Seq = logNext
	logRing[logNext%logCapacity] = entry
	logNext++
}

// admitLog says whether a line of this second is kept, and how many were dropped before it.
func admitLog(second int64) (int64, bool) {
	logMu.Lock()
	defer logMu.Unlock()
	if second != logSecond {
		logSecond, logInSecond = second, 0
	}
	if logInSecond >= maxLogsPerSecond {
		logDropped++
		return 0, false
	}
	logInSecond++
	dropped := logDropped
	logDropped = 0
	return dropped, true
}

func recordLog(message log.Message) {
	// Access and DNS lines name every destination; they show from info up.
	severity := log.Severity_Info
	general, isGeneral := message.(*log.GeneralMessage)
	if isGeneral {
		severity = max(general.Severity, log.Severity_Error)
	}
	if int32(severity) > logLevel.Load() {
		return
	}
	now := logNow()
	dropped, kept := admitLog(now.Unix())
	if !kept {
		return
	}
	var text string
	if isGeneral {
		text = fmt.Sprint(general.Content)
	} else {
		text = message.String()
	}
	// Redacted whole: a cut first would leave a part of an ID or address no pattern matches.
	text = redactLog(text)
	if len(text) > maxLogText {
		text = strings.ToValidUTF8(text[:maxLogText], "") + "…"
	}
	entry := LogEntry{Time: now.UnixMilli(), Level: logLevelNames[severity], Text: text}
	logMu.Lock()
	defer logMu.Unlock()
	if dropped > 0 {
		appendLogLocked(LogEntry{Time: entry.Time, Level: logLevelNames[log.Severity_Warning],
			Text: fmt.Sprintf("%d log lines dropped: more than %d a second", dropped, maxLogsPerSecond)})
	}
	appendLogLocked(entry)
}

var (
	logURL         = regexp.MustCompile(`\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s"'<>]+`)
	logCredentials = regexp.MustCompile(`[^\s/@:"'\[\]]+:[^\s/@"']+@`)
	logUUID        = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
	logIPv6        = regexp.MustCompile(`\[?[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*\]?`)
	logIPv4        = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
	logHost        = regexp.MustCompile(`(?i)\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z][a-z0-9-]{0,61}[a-z0-9])\b`)
	logToken       = regexp.MustCompile(`[A-Za-z0-9+/_-]{20,}={0,2}`)
	logHex         = regexp.MustCompile(`\b[0-9A-Fa-f]{16,}\b`)
	logUserPath    = regexp.MustCompile(`(?i)([\\/](?:users|home)[\\/])[^\\/\s"']+`)
	// File names in core errors, not hosts. Real top-level domains such as .so or .app stay redacted.
	logFileSuffixes = map[string]bool{"dat": true, "json": true, "go": true, "db": true, "txt": true, "yaml": true,
		"yml": true, "log": true, "exe": true, "dll": true, "dylib": true, "conf": true, "mmdb": true, "srs": true}
)

func redactLog(text string) string {
	text = logURL.ReplaceAllString(text, "$1://[redacted]")
	text = logCredentials.ReplaceAllString(text, "[credentials]@")
	text = logUUID.ReplaceAllString(text, "[id]")
	text = logIPv6.ReplaceAllStringFunc(text, func(match string) string {
		address := strings.TrimRight(strings.Trim(match, "[]"), ".:")
		if ip := net.ParseIP(address); ip == nil || ip.To4() != nil || keptAddress(ip) {
			return match
		}
		// The brackets around the address go with it; trailing punctuation stays.
		return "[ip]" + strings.TrimPrefix(strings.TrimPrefix(strings.TrimPrefix(match, "["), address), "]")
	})
	text = logIPv4.ReplaceAllStringFunc(text, func(match string) string {
		if ip := net.ParseIP(match); ip == nil || keptAddress(ip) {
			return match
		}
		return "[ip]"
	})
	text = logHost.ReplaceAllStringFunc(text, func(match string) string {
		if logFileSuffixes[strings.ToLower(match[strings.LastIndexByte(match, '.')+1:])] {
			return match
		}
		return "[host]"
	})
	text = logUserPath.ReplaceAllString(text, "$1[user]")
	text = logToken.ReplaceAllStringFunc(text, func(match string) string {
		if strings.ContainsAny(match, "0123456789") && strings.ToLower(match) != match && strings.ToUpper(match) != match {
			return "[key]"
		}
		return match
	})
	return logHex.ReplaceAllString(text, "[key]")
}

// Loopback and unspecified addresses say which local listener failed and identify no one.
func keptAddress(ip net.IP) bool { return ip.IsLoopback() || ip.IsUnspecified() }
