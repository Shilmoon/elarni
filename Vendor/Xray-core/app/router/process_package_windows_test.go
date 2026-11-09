//go:build windows

package router

import (
	"path/filepath"
	"testing"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

// Elarni: a rule saved for one version of a Microsoft Store app (its package folder, the family
// form the app picker saves, or an exact executable path from before) matches the next version,
// and never another package or another volume's copy.
func TestStoreAppRulesMatchTheUpdatedPackage(t *testing.T) {
	running := `C:\Program Files\WindowsApps\Claude_4.24001.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe`
	previous := lookupProcess
	lookupProcess = func(string, string, uint16, string, uint16) (int, string, string, error) {
		// FindProcess reports the path with forward slashes.
		return 4242, "Claude", filepath.ToSlash(running), nil
	}
	t.Cleanup(func() { lookupProcess = previous })
	connection := func() *routingsession.Context {
		return &routingsession.Context{
			Inbound:  &session.Inbound{Source: net.TCPDestination(net.LocalHostIP, 50000)},
			Outbound: &session.Outbound{Target: net.TCPDestination(net.ParseAddress("1.2.3.10"), 443)},
		}
	}
	for _, tc := range []struct {
		rule  string
		match bool
	}{
		{`C:\Program Files\WindowsApps\Claude_4.23118.0.0_x64__pzs8sxrjxfjjc\`, true},
		{`C:\Program Files\WindowsApps\Claude_pzs8sxrjxfjjc\`, true},
		{`C:\Program Files\WindowsApps\Claude_4.23118.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe`, true},
		{`C:\Program Files\WindowsApps\Claude_4.23118.0.0_x64__pzs8sxrjxfjjc\app\Other.exe`, false},
		{`C:\Program Files\WindowsApps\Claude_4.23118.0.0_x64__8wekyb3d8bbwe\`, false},
		{`C:\Program Files\WindowsApps\ClaudeBeta_pzs8sxrjxfjjc\`, false},
		{`D:\WindowsApps\Claude_pzs8sxrjxfjjc\`, false},
	} {
		if got := NewProcessNameMatcher([]string{tc.rule}).Apply(connection()); got != tc.match {
			t.Errorf("rule %q matched %s: %v, want %v", tc.rule, running, got, tc.match)
		}
	}
}
