//go:build elarni_recording || elarni_diagnostics

package flightrecorder

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const fileBytes = 8 << 20
const retention = 72 * time.Hour

var errInvalid = errors.New("diagnostics operation failed")

// ErrEmpty means an export found no recording to package.
var ErrEmpty = errors.New("diagnostics recording is empty")
var active atomic.Pointer[recorder]
var startMu sync.Mutex
var ids atomic.Uint64

// Phones keep a smaller rolling budget to spare flash space.
var retainedBytes int64 = 256 << 20

func init() {
	if runtime.GOOS == "android" || runtime.GOOS == "ios" {
		retainedBytes = 64 << 20
	}
}

// Enabled reports whether a client started collection; instrumentation skips its work otherwise.
func Enabled() bool { return active.Load() != nil }

type entry struct {
	Event
	Time        string `json:"time"`
	MonotonicMS int64  `json:"monotonicMs"`
	PID         int    `json:"pid"`
	Role        string `json:"role"`
	Dropped     uint64 `json:"dropped,omitempty"`
}
type item struct {
	event   Event
	at      time.Time
	barrier chan struct{}
}
type recorder struct {
	dir, role, prefix string
	start             time.Time
	queue             chan item
	dropped           atomic.Uint64
	writeFailed       atomic.Bool
	root              *os.Root
	out               *os.File
	owner             int
	file              string
	size              int64
	sequence          int
	created           bool
	stop, done        chan struct{}
}

func NextID() uint64 { return ids.Add(1) }

func Record(event Event) {
	r := active.Load()
	if r == nil {
		return
	}
	// Only static event labels and numeric metadata enter the durable log.
	if !token(event.Name) || (event.Code != "" && !token(event.Code)) {
		r.dropped.Add(1)
		return
	}
	values := make(map[string]int64, len(event.Values))
	for k, v := range event.Values {
		if !token(k) || len(values) >= 32 {
			r.dropped.Add(1)
			return
		}
		values[k] = v
	}
	event.Values = values
	select {
	case r.queue <- item{event: event, at: time.Now()}:
	default:
		r.dropped.Add(1)
	}
}

func token(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if c != '_' && (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func start(directory, role string, owner int) error {
	startMu.Lock()
	defer startMu.Unlock()
	if role != "host" && role != "provider" && role != "helper" {
		return errInvalid
	}
	if r := active.Load(); r != nil {
		if r.dir == directory && r.role == role {
			return nil
		}
		return errInvalid
	}
	if !filepath.IsAbs(directory) {
		return errInvalid
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return errInvalid
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return errInvalid
	}
	now := time.Now()
	r := &recorder{dir: directory, role: role, root: root, owner: owner, start: now,
		prefix: fmt.Sprintf("rvdiag-%s-%d-%d", role, os.Getpid(), now.UnixNano()), queue: make(chan item, 4096), stop: make(chan struct{}), done: make(chan struct{})}
	active.Store(r)
	go r.run()
	Record(Event{Name: "collector_started", Values: map[string]int64{"schema": 2, "retention_hours": 72, "retained_bytes": retainedBytes}})
	return nil
}

// halt stops collection and returns once the segment is closed, so it can be exported or removed.
func halt() {
	startMu.Lock()
	defer startMu.Unlock()
	if r := active.Swap(nil); r != nil {
		close(r.stop)
		<-r.done
	}
}

func (r *recorder) run() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	defer close(r.done)
	defer r.root.Close()
	defer r.closeFile()
	for ticks := 1; ; {
		select {
		case <-r.stop:
			return
		case item := <-r.queue:
			if item.barrier != nil {
				close(item.barrier)
			} else {
				r.write(item.event, item.at)
			}
		case <-ticker.C:
			var m runtime.MemStats
			runtime.ReadMemStats(&m)
			r.write(Event{Name: "go_runtime", Values: map[string]int64{"heap": int64(m.Alloc), "heap_sys": int64(m.HeapSys), "goroutines": int64(runtime.NumGoroutine()), "gc_count": int64(m.NumGC), "gc_pause_ns": int64(m.PauseTotalNs)}}, time.Now())
			sampleConnections(ticks%10 == 0)
			ticks++
		}
	}
}

func (r *recorder) write(event Event, at time.Time) {
	if r.file == "" || r.size >= fileBytes {
		r.closeFile()
		r.sequence++
		r.file = fmt.Sprintf("%s-%06d.jsonl", r.prefix, r.sequence)
		r.size = 0
		r.created = false
		r.prune()
	}
	line, err := json.Marshal(entry{Event: event, Time: at.UTC().Format(time.RFC3339Nano), MonotonicMS: at.Sub(r.start).Milliseconds(), PID: os.Getpid(), Role: r.role, Dropped: r.dropped.Load()})
	if err != nil {
		r.writeFailed.Store(true)
		return
	}
	// The segment stays open: reopening it per event cost ~35x more CPU. Writes are unbuffered, so a crash loses nothing extra.
	if r.out == nil {
		flags := os.O_CREATE | os.O_APPEND | os.O_WRONLY
		if !r.created {
			flags |= os.O_EXCL // A root core never appends to a name planted in its user's directory.
		}
		if r.out, err = r.root.OpenFile(r.file, flags, 0600); err != nil {
			r.writeFailed.Store(true)
			return
		}
		if !r.created && r.owner > 0 {
			_ = r.out.Chown(r.owner, -1) // Unreadable segments still serve a root export.
		}
		r.created = true
	}
	n, err := r.out.Write(append(line, '\n'))
	r.size += int64(n)
	if err != nil {
		r.closeFile()
	}
	r.writeFailed.Store(err != nil)
}

func (r *recorder) closeFile() {
	if r.out != nil {
		r.out.Close()
		r.out = nil
	}
}

func (r *recorder) files() []os.FileInfo {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		return nil
	}
	var result []os.FileInfo
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "rvdiag-") || !strings.HasSuffix(e.Name(), ".jsonl") || e.Type()&os.ModeSymlink != 0 {
			continue
		}
		// Not e.Info(): on Windows a listing keeps the size and time a segment had when it was opened.
		if info, err := r.root.Lstat(e.Name()); err == nil && info.Mode().IsRegular() {
			result = append(result, info)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ModTime().Before(result[j].ModTime()) })
	return result
}

func (r *recorder) prune() {
	files := r.files()
	var total int64
	for _, f := range files {
		total += f.Size()
	}
	for _, f := range files {
		if f.Name() == r.file {
			continue
		}
		if total <= retainedBytes-fileBytes && time.Since(f.ModTime()) <= retention {
			continue
		}
		if r.root.Remove(f.Name()) == nil {
			total -= f.Size()
		}
	}
}

func (r *recorder) flush() error {
	done := make(chan struct{})
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case r.queue <- item{barrier: done}:
	case <-timer.C:
		return errInvalid
	}
	select {
	case <-done:
		if r.writeFailed.Load() {
			return errInvalid
		}
		return nil
	case <-timer.C:
		return errInvalid
	}
}

type segment struct {
	root *os.Root
	info os.FileInfo
}

// export packages the segments of every directory, newest first within the budget: a root
// VPN core records apart from its user's app. Missing directories just held no recording.
func export(directories []string, destination string, dropped uint64) error {
	if !filepath.IsAbs(destination) {
		return errInvalid
	}
	var segments []segment
	for _, directory := range directories {
		if !filepath.IsAbs(directory) || filepath.Clean(filepath.Dir(destination)) == filepath.Clean(directory) {
			return errInvalid
		}
		root, err := os.OpenRoot(directory)
		if err != nil {
			continue
		}
		defer root.Close()
		for _, info := range (&recorder{dir: directory, root: root}).files() {
			segments = append(segments, segment{root, info})
		}
	}
	if len(segments) == 0 {
		return ErrEmpty
	}
	sort.Slice(segments, func(i, j int) bool { return segments[i].info.ModTime().After(segments[j].info.ModTime()) })
	// Export only the collectors' regular JSONL files, never the surrounding app group.
	f, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return errInvalid
	}
	complete := false
	defer func() {
		f.Close()
		if !complete {
			os.Remove(destination)
		}
	}()
	z := zip.NewWriter(f)
	manifest, err := z.Create("manifest.json")
	if err != nil {
		return errInvalid
	}
	if err := json.NewEncoder(manifest).Encode(map[string]any{"schema": 1, "exportedAt": time.Now().UTC(), "goVersion": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH, "dropped": dropped, "contains": "structured events only; no profiles, credentials, payloads or endpoint URLs"}); err != nil {
		return errInvalid
	}
	var total int64
	for _, s := range segments {
		info := s.info
		if time.Since(info.ModTime()) > retention {
			continue
		}
		if info.Size() > fileBytes+65536 || total+info.Size() > retainedBytes+fileBytes {
			continue
		}
		source, err := s.root.Open(info.Name())
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return errInvalid
		}
		actual, err := source.Stat()
		if err != nil || !os.SameFile(info, actual) || !actual.Mode().IsRegular() {
			source.Close()
			return errInvalid
		}
		out, err := z.Create(info.Name())
		if err != nil {
			source.Close()
			return errInvalid
		}
		_, err = io.CopyN(out, source, info.Size())
		source.Close()
		if err != nil {
			return errInvalid
		}
		total += info.Size()
	}
	if z.Close() != nil || f.Sync() != nil || f.Close() != nil {
		return errInvalid
	}
	complete = true
	return nil
}

func command(request Request) (any, error) {
	if request.Action == "start" {
		if err := start(request.Directory, request.Role, request.Owner); err != nil {
			return nil, err
		}
	}
	r := active.Load()
	if request.Action == "status" || request.Action == "start" {
		result := map[string]any{"enabled": true, "collecting": r != nil}
		if r != nil {
			result["dropped"] = r.dropped.Load()
			result["writeFailed"] = r.writeFailed.Load()
		}
		return result, nil
	}
	if request.Action == "stop" {
		if r != nil {
			_ = r.flush()
		}
		halt()
		return map[string]bool{"stopped": true}, nil
	}
	if request.Action == "export" {
		directories := request.Directories
		if request.Directory != "" {
			directories = append([]string{request.Directory}, directories...)
		}
		var dropped uint64
		if r != nil {
			if err := r.flush(); err != nil {
				return nil, err
			}
			dropped = r.dropped.Load()
			if len(directories) == 0 {
				directories = []string{r.dir}
			}
		}
		// Recording may be off while earlier segments remain, so export needs no collector.
		return map[string]bool{"exported": true}, export(directories, request.Destination, dropped)
	}
	if r == nil {
		return nil, errInvalid
	}
	switch request.Action {
	case "event":
		switch request.Kind {
		case "app_state", "network_path", "provider_boundary", "provider_start", "provider_stop", "sleep", "wake", "runtime_metrics", "settings", "subscription_refresh":
		default:
			return nil, errInvalid
		}
		Record(Event{Name: request.Kind, Values: request.Values})
	case "mark":
		// The marker carries a full snapshot of open connections at the moment the user saw the problem.
		Record(Event{Name: "user_stall_marker"})
		sampleConnections(true)
		return map[string]bool{"marked": true}, r.flush()
	case "flush":
		return map[string]bool{"flushed": true}, r.flush()
	default:
		return nil, errInvalid
	}
	return map[string]bool{"recorded": true}, nil
}
