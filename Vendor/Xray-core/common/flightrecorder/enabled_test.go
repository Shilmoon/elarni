//go:build elarni_recording || elarni_diagnostics

package flightrecorder

import (
	"archive/zip"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCollectorExportContainsOnlyTypedEvents(t *testing.T) {
	directory := t.TempDir()
	if err := start(directory, "helper", 0); err != nil {
		t.Fatal(err)
	}
	r := active.Load()
	defer halt()
	secret := filepath.Join(t.TempDir(), "private.json")
	if err := os.WriteFile(secret, []byte("fixture-secret-do-not-export"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(directory, "rvdiag-symlink.jsonl")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "profile.json"), []byte("fixture-secret-do-not-export"), 0600); err != nil {
		t.Fatal(err)
	}
	Record(Event{Name: "fixture-secret-do-not-export"})
	Record(Event{Name: "fixture_event", Values: map[string]int64{"bytes": 42}})
	a, b := net.Pipe()
	measured := TrackConn(a, 7, 9, "xhttp_stream")
	go func() { _, _ = b.Write([]byte("payload-must-not-be-recorded")); b.Close() }()
	_, _ = io.Copy(io.Discard, measured)
	measured.Close()
	// Datagram tracking must preserve message boundaries, source addresses,
	// zero-length packets and deadlines while exporting only numeric metadata.
	packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tracked := TrackPacketConn(packet, 11, 13, "wg_transport")
	defer tracked.Close()
	peer, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	tracked.SetDeadline(time.Now().Add(5 * time.Second))
	peer.SetDeadline(time.Now().Add(5 * time.Second))
	for _, payload := range [][]byte{[]byte("datagram-must-not-be-recorded"), {}} {
		if _, err := peer.WriteTo(payload, tracked.LocalAddr()); err != nil {
			t.Fatal(err)
		}
		buffer := make([]byte, 128)
		n, from, err := tracked.ReadFrom(buffer)
		if err != nil || string(buffer[:n]) != string(payload) || from.String() != peer.LocalAddr().String() {
			t.Fatalf("datagram read changed: %v", err)
		}
		if _, err := tracked.WriteTo(buffer[:n], from); err != nil {
			t.Fatal(err)
		}
		n, from, err = peer.ReadFrom(buffer)
		if err != nil || string(buffer[:n]) != string(payload) || from.String() != tracked.LocalAddr().String() {
			t.Fatalf("datagram reply changed: %v", err)
		}
	}
	tracked.SetReadDeadline(time.Now().Add(-time.Second))
	if _, _, err := tracked.ReadFrom(make([]byte, 1)); err == nil {
		t.Fatal("packet read deadline was lost")
	}
	sampleConnections(true)
	tracked.Close()
	if _, err := command(Request{Action: "mark"}); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "export.zip")
	if err := export([]string{directory}, destination, r.dropped.Load()); err != nil {
		t.Fatal(err)
	}
	if err := export([]string{directory}, destination, 0); err == nil {
		t.Fatal("export overwrote an existing file")
	}
	z, err := zip.OpenReader(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	var joined strings.Builder
	for _, file := range z.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(reader)
		reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		joined.Write(data)
	}
	text := joined.String()
	for _, prohibited := range []string{"fixture-secret-do-not-export", "payload-must-not-be-recorded", "datagram-must-not-be-recorded", "127.0.0.1", directory, secret} {
		if strings.Contains(text, prohibited) {
			t.Fatal("export contained unrelated or private data")
		}
	}
	for _, required := range []string{"fixture_event", "user_stall_marker", "xhttp_stream_closed", "wg_transport_progress", "wg_transport_closed", "read_bytes", "monotonicMs"} {
		if !strings.Contains(text, required) {
			t.Fatalf("export lost %s", required)
		}
	}
	var packetClosed, packetTimeout bool
	for _, line := range strings.Split(text, "\n") {
		var event Event
		if json.Unmarshal([]byte(line), &event) != nil {
			continue
		}
		if event.Name == "wg_transport_closed" {
			packetClosed = true
			if event.Values["read_bytes"] != int64(len("datagram-must-not-be-recorded")) || event.Values["written_bytes"] != int64(len("datagram-must-not-be-recorded")) || event.Values["read_ops"] != 2 || event.Values["write_ops"] != 2 || event.Values["parent"] != 11 || event.Session != 13 || event.Values["pending_reads"] != 0 {
				t.Fatalf("wrong packet counters: %+v", event)
			}
		}
		if event.Name == "wg_transport_read_done" && event.Code == "timeout" {
			packetTimeout = true
		}
	}
	if !packetClosed || !packetTimeout {
		t.Fatal("packet close or timeout evidence missing")
	}
	if r.dropped.Load() != 1 {
		t.Fatal("invalid event was not accounted for")
	}
}

func TestCollectorRotationRetentionAndEventTime(t *testing.T) {
	directory := t.TempDir()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	start := time.Now().Add(-time.Minute)
	r := &recorder{dir: directory, root: root, role: "helper", prefix: "rvdiag-test", start: start}
	at := start.Add(time.Second)
	r.write(Event{Name: "first"}, at)
	r.size = fileBytes
	r.write(Event{Name: "second"}, time.Now())
	if len(r.files()) != 2 {
		t.Fatal("segment was not rotated")
	}
	data, err := os.ReadFile(filepath.Join(directory, "rvdiag-test-000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var line entry
	if err := json.Unmarshal(data, &line); err != nil {
		t.Fatal(err)
	}
	if line.MonotonicMS != 1000 || line.Time != at.UTC().Format(time.RFC3339Nano) {
		t.Fatal("queue delay changed the event time")
	}
	expired := filepath.Join(directory, "rvdiag-expired.jsonl")
	if err := os.WriteFile(expired, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-retention - time.Hour)
	if err := os.Chtimes(expired, old, old); err != nil {
		t.Fatal(err)
	}
	r.prune()
	if _, err := os.Stat(expired); !os.IsNotExist(err) {
		t.Fatal("expired log was retained")
	}
	// Sparse synthetic segments exercise the byte budget without allocating payloads.
	for i := 0; i < 33; i++ {
		file, err := os.CreateTemp(directory, "rvdiag-budget-*.jsonl")
		if err != nil {
			t.Fatal(err)
		}
		if err := file.Truncate(fileBytes); err != nil {
			file.Close()
			t.Fatal(err)
		}
		file.Close()
	}
	r.prune()
	var total int64
	for _, file := range r.files() {
		total += file.Size()
	}
	if total > retainedBytes {
		t.Fatal("retention exceeded the byte budget")
	}
}

func TestCollectionIsIdleUntilStartedAndExportsAfterStop(t *testing.T) {
	directory := t.TempDir()
	if Enabled() {
		t.Fatal("collecting before start")
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if TrackConn(a, 0, 0, "fixture") != a {
		t.Fatal("idle recorder wrapped a connection")
	}
	for _, action := range []string{"mark", "flush", "event"} {
		if _, err := command(Request{Action: action, Kind: "settings"}); err == nil {
			t.Fatalf("%s accepted while idle", action)
		}
	}
	empty := filepath.Join(t.TempDir(), "empty.zip")
	if _, err := command(Request{Action: "export", Directory: directory, Destination: empty}); err != ErrEmpty {
		t.Fatalf("empty export: %v", err)
	}
	if _, err := os.Stat(empty); !os.IsNotExist(err) {
		t.Fatal("empty export left a file")
	}
	if _, err := command(Request{Action: "start", Directory: directory, Role: "host"}); err != nil || !Enabled() {
		t.Fatal("start failed")
	}
	if _, err := command(Request{Action: "mark"}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := command(Request{Action: "stop"}); err != nil || Enabled() {
			t.Fatal("stop failed")
		}
	}
	// A root VPN core records in its own directory; export merges it and skips missing ones.
	elevated := t.TempDir()
	if err := os.WriteFile(filepath.Join(elevated, "rvdiag-helper-1-1-000001.jsonl"), []byte(`{"event":"elevated_fixture"}`+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "stored.zip")
	if _, err := command(Request{Action: "export", Directory: directory, Directories: []string{filepath.Join(elevated, "missing"), elevated}, Destination: destination}); err != nil {
		t.Fatal(err)
	}
	z, err := zip.OpenReader(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	var text strings.Builder
	for _, file := range z.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(reader)
		reader.Close()
		text.Write(data)
	}
	if !strings.Contains(text.String(), "user_stall_marker") || !strings.Contains(text.String(), `"schema":2`) || !strings.Contains(text.String(), "elevated_fixture") {
		t.Fatal("stored export lost the recording")
	}
}

func TestProgressSkipsIdleConnectionsExceptSnapshots(t *testing.T) {
	// No writer goroutine: the queue is inspected directly, away from the 1 s sampler.
	r := &recorder{queue: make(chan item, 64)}
	active.Store(r)
	defer active.Store(nil)
	a, b := net.Pipe()
	defer b.Close()
	c := TrackConn(a, 0, 0, "fixture_stream")
	defer c.Close()
	progress := func(all bool) (n int) {
		for len(r.queue) > 0 {
			<-r.queue
		}
		sampleConnections(all)
		for len(r.queue) > 0 {
			if (<-r.queue).event.Name == "fixture_stream_progress" {
				n++
			}
		}
		return n
	}
	go b.Write([]byte("x"))
	if _, err := c.Read(make([]byte, 1)); err != nil {
		t.Fatal(err)
	}
	if progress(false) != 1 {
		t.Fatal("active connection was not sampled")
	}
	if progress(false) != 0 {
		t.Fatal("idle connection was sampled")
	}
	if progress(true) != 1 {
		t.Fatal("snapshot skipped an idle connection")
	}
}

func TestNewSegmentNeverAppendsToAPlantedFile(t *testing.T) {
	directory := t.TempDir()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	planted := filepath.Join(directory, "rvdiag-planted-000001.jsonl")
	if err := os.WriteFile(planted, []byte("planted\n"), 0600); err != nil {
		t.Fatal(err)
	}
	r := &recorder{dir: directory, root: root, role: "helper", prefix: "rvdiag-planted", start: time.Now()}
	defer r.closeFile()
	r.write(Event{Name: "first"}, time.Now())
	if data, _ := os.ReadFile(planted); !r.writeFailed.Load() || string(data) != "planted\n" {
		t.Fatal("recorder appended to a file it did not create")
	}
}
