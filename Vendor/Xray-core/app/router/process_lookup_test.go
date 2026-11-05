package router

import (
	"fmt"
	"testing"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

// Elarni: every process rule looked the process up again, and on Windows each lookup scans every
// TCP row of the host (about 1.2 us a row). Per-app targets compile to one rule per target, so a
// connection with four targets paid four scans, about 40 ms with 8000 rows.
func TestProcessRulesOfOneRoutingDecisionShareOneLookup(t *testing.T) {
	calls := 0
	previous := lookupProcess
	lookupProcess = func(network, srcIP string, srcPort uint16, dstIP string, dstPort uint16) (int, string, string, error) {
		calls++
		return 4242, "browser", "c:/apps/browser.exe", nil
	}
	t.Cleanup(func() { lookupProcess = previous })

	matchers := []*ProcessNameMatcher{
		NewProcessNameMatcher([]string{"game.exe"}),
		NewProcessNameMatcher([]string{"telegram"}),
		NewProcessNameMatcher([]string{"steam"}),
		NewProcessNameMatcher([]string{"browser"}),
	}
	connection := func() *routingsession.Context {
		return &routingsession.Context{
			Inbound:  &session.Inbound{Source: net.TCPDestination(net.LocalHostIP, 50000)},
			Outbound: &session.Outbound{Target: net.TCPDestination(net.ParseAddress("1.2.3.10"), 443)},
		}
	}

	ctx := connection()
	var matched []bool
	for _, m := range matchers {
		matched = append(matched, m.Apply(ctx))
	}
	if calls != 1 {
		t.Fatalf("%d lookups for one routing decision, want 1", calls)
	}
	if matched[0] || matched[1] || matched[2] || !matched[3] {
		t.Fatalf("matches %v, want only the last rule", matched)
	}
	// A new connection is a new socket and may belong to another process.
	matchers[0].Apply(connection())
	if calls != 2 {
		t.Fatalf("%d lookups after a second connection, want 2", calls)
	}
}

type quietHandler struct{}

func (quietHandler) Handle(log.Message)     {}
func (quietHandler) Severity() log.Severity { return log.Severity_Unknown }

// Routing a connection whose process lookup fails, with the core's log off and the app's log tap at
// its default warning level, through the per-app rules of three targets.
func BenchmarkProcessRulesOfAFailedLookup(b *testing.B) {
	previous := lookupProcess
	lookupProcess = func(string, string, uint16, string, uint16) (int, string, string, error) {
		return 0, "", "", errors.New("failed to find the process")
	}
	log.RegisterHandler(quietHandler{})
	kept := 0
	log.SetTap(func(m log.Message) { kept += len(fmt.Sprint(m.(*log.GeneralMessage).Content)) }, func() log.Severity { return log.Severity_Warning })
	b.Cleanup(func() {
		lookupProcess = previous
		log.SetTap(nil, nil)
		log.RegisterHandler(log.NewLogger(log.CreateStdoutLogWriter()))
	})
	matchers := []*ProcessNameMatcher{
		NewProcessNameMatcher([]string{"game.exe"}),
		NewProcessNameMatcher([]string{"telegram"}),
		NewProcessNameMatcher([]string{"browser"}),
	}
	b.ReportAllocs()
	for b.Loop() {
		ctx := &routingsession.Context{
			Inbound:  &session.Inbound{Source: net.TCPDestination(net.LocalHostIP, 50000)},
			Outbound: &session.Outbound{Target: net.TCPDestination(net.ParseAddress("1.2.3.10"), 443)},
		}
		for _, m := range matchers {
			m.Apply(ctx)
		}
	}
}
