package xray

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
)

func TestRedactLogKeepsTheMessageAndHidesKeysHostsAndAddresses(t *testing.T) {
	for _, item := range []struct{ input, want string }{
		{"proxy/vless/outbound: tunneling request to tcp:www.example.com:443 via 203.0.113.7:8443",
			"proxy/vless/outbound: tunneling request to tcp:[host]:443 via [ip]:8443"},
		{"dial tcp [2001:db8::1]:443: i/o timeout, then 2001:db8::2.", "dial tcp [ip]:443: i/o timeout, then [ip]."},
		{"invalid user id 3f2504e0-4f89-11d3-9a0c-0305e82c3301", "invalid user id [id]"},
		{`Post "https://cdn.example.net/secret-path?x=1": EOF`, `Post "https://[redacted]": EOF`},
		{"socks5 login alice:hunter2@proxy.example.org failed", "socks5 login [credentials]@[host] failed"},
		{"reality: public key SdLZbGRo7ZLM9Kx0lhkWuTyRxR3Lhe5BAYFhBVP3Ckc short id 0123456789abcdef",
			"reality: public key [key] short id [key]"},
		{`open C:\Users\alice\AppData\geosite.dat: denied, /home/bob/.config x`, `open C:\Users\[user]\AppData\geosite.dat: denied, /home/[user]/.config x`},
		{"app/dispatcher: taking detour [direct] for [udp:127.0.0.1:53] from ::1 and 0.0.0.0",
			"app/dispatcher: taking detour [direct] for [udp:127.0.0.1:53] from ::1 and 0.0.0.0"},
		{"transport/internet/splithttp: elarni.exe read config.json at 12:34:56", "transport/internet/splithttp: elarni.exe read config.json at 12:34:56"},
	} {
		if got := redactLog(item.input); got != item.want {
			t.Errorf("redactLog(%q)\n got %q\nwant %q", item.input, got, item.want)
		}
	}
}

func TestLogsKeepOnlyTheChosenLevelAndReachEveryReader(t *testing.T) {
	defer resetLogs()
	resetLogs()
	if level := LogLevel(); level != "warning" {
		t.Fatalf("default level %q, want warning", level)
	}
	// Xray's own logger may be registered at level none; the tap still sees every message.
	log.RegisterHandler(noopHandler{})
	ctx := context.Background()
	errors.LogInfo(ctx, "hidden at warning")
	errors.LogWarning(ctx, "dial to 198.51.100.4:443 failed")
	if err := SetLogLevel("verbose"); err == nil {
		t.Fatal("accepted an unknown log level")
	}
	if err := SetLogLevel("debug"); err != nil {
		t.Fatal(err)
	}
	errors.LogDebug(ctx, "debug line")
	log.Record(&log.AccessMessage{From: "127.0.0.1:5000", To: "tcp:example.com:443", Status: log.AccessAccepted, Detour: "proxy"})
	if err := SetLogLevel("none"); err != nil {
		t.Fatal(err)
	}
	errors.LogError(ctx, "dropped at none")

	all := ReadLogs(0)
	if all.Level != "none" || len(all.Entries) != 3 || all.Last != all.Entries[2].Seq {
		t.Fatalf("got %+v", all)
	}
	first, second, third := all.Entries[0], all.Entries[1], all.Entries[2]
	if first.Level != "warning" || !strings.HasSuffix(first.Text, "dial to [ip]:443 failed") || first.Time == 0 {
		t.Fatalf("warning entry %+v", first)
	}
	if second.Level != "debug" || !strings.HasSuffix(second.Text, "debug line") {
		t.Fatalf("debug entry %+v", second)
	}
	if third.Level != "info" || !strings.Contains(third.Text, "tcp:[host]:443") || !strings.Contains(third.Text, "[proxy]") {
		t.Fatalf("access entry %+v", third)
	}
	if later := ReadLogs(second.Seq); len(later.Entries) != 1 || later.Entries[0] != third {
		t.Fatalf("a reader after %d got %+v", second.Seq, later.Entries)
	}
}

// setLogClock serves times step apart.
func setLogClock(t *testing.T, step time.Duration) *time.Time {
	clock := time.Unix(1_700_000_000, 0)
	logNow = func() time.Time { clock = clock.Add(step); return clock }
	t.Cleanup(func() { logNow = time.Now })
	return &clock
}

func TestLogsKeepTheNewestLinesAndRenumberRelayedOnes(t *testing.T) {
	defer resetLogs()
	resetLogs()
	setLogClock(t, time.Second) // below the per-second cap
	for index := 0; index < logCapacity+5; index++ {
		errors.LogWarning(context.Background(), fmt.Sprint("line ", index))
	}
	all := ReadLogs(0)
	if len(all.Entries) != logCapacity || !strings.HasSuffix(all.Entries[0].Text, "line 5") ||
		all.Entries[logCapacity-1].Seq != int64(logCapacity+5) {
		t.Fatalf("kept %d lines from %+v", len(all.Entries), all.Entries[0])
	}
	long := strings.Repeat("a", 3*maxLogText)
	errors.LogWarning(context.Background(), long)
	if text := ReadLogs(int64(logCapacity + 5)).Entries[0].Text; len(text) > maxLogText+len("…") {
		t.Fatalf("kept %d bytes of one line", len(text))
	}
	// The cut falls inside one of these IDs; what is left of it must not be kept either.
	errors.LogWarning(context.Background(), "start "+strings.Repeat("12345678-9012-4345-8678-901234567890 ", 40))
	if text := ReadLogs(int64(logCapacity + 6)).Entries[0].Text; strings.ContainsAny(text[strings.Index(text, "start ")+6:], "0123456789") {
		t.Fatalf("kept part of an ID: %q", text[len(text)-60:])
	}

	resetLogs()
	// A helper process's lines arrive already filtered and redacted; they keep their time and level.
	AppendLogs([]LogEntry{{Seq: 90, Time: 1700000000000, Level: "error", Text: "helper failed"}})
	relayed := ReadLogs(0).Entries
	if len(relayed) != 1 || relayed[0].Seq != 1 || relayed[0].Time != 1700000000000 || relayed[0].Level != "error" {
		t.Fatalf("relayed %+v", relayed)
	}
}

// In an outage every failed dial logs a line; past the cap the rest of that second is counted,
// and the count is kept before the next line.
func TestLogsKeepAtMostTheCapEachSecond(t *testing.T) {
	defer resetLogs()
	resetLogs()
	clock := setLogClock(t, 0)
	ctx := context.Background()
	for index := range maxLogsPerSecond + 50 {
		errors.LogWarning(ctx, fmt.Sprint("dial ", index, " failed"))
	}
	*clock = clock.Add(time.Second)
	errors.LogWarning(ctx, "after the outage")
	entries := ReadLogs(0).Entries
	if len(entries) != maxLogsPerSecond+2 || !strings.HasSuffix(entries[maxLogsPerSecond-1].Text, fmt.Sprint("dial ", maxLogsPerSecond-1, " failed")) {
		t.Fatalf("kept %d lines, ending %+v", len(entries), entries[len(entries)-1])
	}
	if marker := entries[maxLogsPerSecond]; marker.Level != "warning" || marker.Text != fmt.Sprintf("50 log lines dropped: more than %d a second", maxLogsPerSecond) {
		t.Fatalf("drop marker %+v", marker)
	}
	if last := entries[len(entries)-1]; !strings.HasSuffix(last.Text, "after the outage") {
		t.Fatalf("the next second's line %+v", last)
	}
}

// An outage logs a failed dial per connection attempt; "kept" is a line a second, all redacted.
func BenchmarkRecordLog(b *testing.B) {
	for _, name := range []string{"flood", "kept"} {
		b.Run(name, func(b *testing.B) {
			defer resetLogs()
			resetLogs()
			if name == "kept" {
				clock := time.Unix(1_700_000_000, 0)
				logNow = func() time.Time { clock = clock.Add(time.Second); return clock }
				defer func() { logNow = time.Now }()
			}
			log.RegisterHandler(noopHandler{})
			ctx := context.Background()
			b.ReportAllocs()
			for b.Loop() {
				errors.LogWarning(ctx, "transport/internet: failed to dial tcp:www.example.com:443 via 203.0.113.7:8443 > i/o timeout")
			}
		})
	}
}

type noopHandler struct{}

func (noopHandler) Handle(log.Message) {}

type silentHandler struct{}

func (silentHandler) Handle(log.Message)     {}
func (silentHandler) Severity() log.Severity { return log.Severity_Unknown }

// Every connection and UDP packet logs at debug and info; with the core's own log at none,
// only the kept level may make Xray build those messages.
func TestLogsBuildOnlyMessagesTheKeptLevelShows(t *testing.T) {
	defer resetLogs()
	resetLogs()
	log.RegisterHandler(silentHandler{})
	if got := log.GetSeverity(); got != log.Severity_Warning {
		t.Fatalf("severity %v at the default level, want Warning", got)
	}
	if err := SetLogLevel("debug"); err != nil {
		t.Fatal(err)
	}
	if got := log.GetSeverity(); got != log.Severity_Debug {
		t.Fatalf("severity %v at debug, want Debug", got)
	}
	if err := SetLogLevel("none"); err != nil {
		t.Fatal(err)
	}
	if got := log.GetSeverity(); got != log.Severity_Unknown {
		t.Fatalf("severity %v at none, want Unknown", got)
	}
}
