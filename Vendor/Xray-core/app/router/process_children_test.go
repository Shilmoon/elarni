package router

import (
	"testing"

	"github.com/xtls/xray-core/common/net"
)

// "children:<rule>" also matches the programs an app starts, and theirs, as Claude starts
// Claude Code and Discord starts its updater; plain rules never ask for parents.
func TestChildrenRulesMatchTheProgramsAnAppStarts(t *testing.T) {
	previous := parentProcess
	t.Cleanup(func() { parentProcess = previous })
	tree := map[int]net.Process{
		30: {PID: 20, Name: "claude", Path: "/opt/claude/claude"},
		20: {PID: 10, Name: "launcher", Path: "/usr/bin/launcher"},
		10: {PID: 1, Name: "systemd", Path: "/usr/lib/systemd/systemd"},
	}
	asked := 0
	parentProcess = func(pid int) (net.Process, bool) {
		asked++
		parent, ok := tree[pid]
		return parent, ok
	}
	for _, c := range []struct {
		name  string
		rules []string
		pid   int
		path  string
		want  bool
	}{
		{"the app itself", []string{"children:/opt/claude/claude"}, 20, "/opt/claude/claude", true},
		{"a program it started", []string{"children:/opt/claude/claude"}, 30, "/home/u/.local/bin/claude-code", true},
		{"started further up", []string{"children:launcher"}, 30, "/home/u/.local/bin/claude-code", true},
		{"a folder rule", []string{"children:/opt/claude/"}, 30, "/home/u/.local/bin/claude-code", true},
		{"no listed parent", []string{"children:/usr/bin/firefox"}, 30, "/home/u/.local/bin/claude-code", false},
		{"a plain rule ignores parents", []string{"/opt/claude/claude"}, 30, "/home/u/.local/bin/claude-code", false},
		{"a parent's own parent is not its child", []string{"children:/opt/claude/claude"}, 10, "/usr/bin/launcher", false},
	} {
		if got := NewProcessNameMatcher(c.rules).MatchesProcess(c.pid, "", c.path); got != c.want {
			t.Errorf("%s: matched %v, want %v", c.name, got, c.want)
		}
	}
	asked = 0
	NewProcessNameMatcher([]string{"telegram", "/opt/claude/"}).MatchesProcess(30, "claude-code", "/home/u/.local/bin/claude-code")
	if asked != 0 {
		t.Fatalf("plain rules asked for %d parents", asked)
	}
	// A loop of reused IDs ends.
	tree[10] = net.Process{PID: 30, Name: "loop", Path: "/loop"}
	if NewProcessNameMatcher([]string{"children:/nowhere"}).MatchesProcess(30, "x", "/x") {
		t.Fatal("matched through a loop")
	}
	if asked > 2*maxProcessAncestors {
		t.Fatalf("%d parent lookups", asked)
	}
}

// The connections view says which listed program started a connection's program.
func TestChildrenRulesNameTheAncestorThatMatched(t *testing.T) {
	previous := parentProcess
	t.Cleanup(func() { parentProcess = previous })
	parentProcess = func(pid int) (net.Process, bool) {
		if pid == 30 {
			return net.Process{PID: 20, Name: "claude", Path: "/opt/claude/claude"}, true
		}
		return net.Process{}, false
	}
	matcher := NewProcessNameMatcher([]string{"children:/opt/claude/claude"})
	if matched, via := matcher.matchProcess(30, "claude-code", "/home/u/.local/bin/claude-code"); !matched || via != "/opt/claude/claude" {
		t.Fatalf("matched %v via %q", matched, via)
	}
	if matched, via := matcher.matchProcess(20, "claude", "/opt/claude/claude"); !matched || via != "" {
		t.Fatalf("the app itself: matched %v via %q", matched, via)
	}
}
