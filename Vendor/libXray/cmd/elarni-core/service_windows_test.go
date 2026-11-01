//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// serviceFixture serves a private pipe name the way the ElarniVPN service serves
// its own, with a starter that runs a harmless process instead of the helper.
type serviceFixture struct {
	name    string
	starts  []string
	cleared int
}

func startServiceFixture(t *testing.T, users []string, own string) *serviceFixture {
	t.Helper()
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		t.Fatal(err)
	}
	fixture := &serviceFixture{name: `\\.\pipe\Elarni-VPN-Service-test-` + hex.EncodeToString(random[:])}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	stop, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	hooks := vpnServiceHooks{
		own: own,
		start: func(pipe string, broker uint32) (windows.Handle, error) {
			fixture.starts = append(fixture.starts, pipe)
			if broker != windows.GetCurrentProcessId() {
				t.Errorf("the helper was started for process %d", broker)
			}
			command := exec.Command(self, "-test.run=^$")
			if err := command.Start(); err != nil {
				return 0, err
			}
			t.Cleanup(func() { _ = command.Wait() })
			return windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(command.Process.Pid))
		},
		clear: func() error { fixture.cleared++; return nil },
	}
	ready := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- serveVPNService(fixture.name, users, hooks, stop, func() { close(ready) }) }()
	select {
	case <-ready:
	case err := <-done:
		t.Fatal("the service pipe was not served:", err)
	}
	t.Cleanup(func() {
		windows.SetEvent(stop)
		select {
		case err := <-done:
			if err != nil {
				t.Error("serving stopped with", err)
			}
		case <-time.After(5 * time.Second):
			t.Error("the service pipe kept serving after stop")
		}
		windows.CloseHandle(stop)
	})
	return fixture
}

func currentUserSID(t *testing.T) string {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	return user.User.Sid.String()
}

func ownDigest(t *testing.T) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	digest, err := fileDigest(self)
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

var testVPNPipe = vpnPipePrefix + strings.Repeat("ab", 32)

// An allowed account running this build gets the started helper's handle in its
// own process, and the helper learns which broker to serve.
func TestVPNServiceStartsTheHelperForAnAllowedAccount(t *testing.T) {
	fixture := startServiceFixture(t, []string{currentUserSID(t)}, ownDigest(t))
	reply, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "start", Pipe: testVPNPipe})
	if err != nil {
		t.Fatal(err)
	}
	process := windows.Handle(reply.Handle)
	defer windows.CloseHandle(process)
	if _, err := windows.GetProcessId(process); err != nil {
		t.Fatal("the reply is no process handle of this process:", err)
	}
	if strings.Join(fixture.starts, ",") != testVPNPipe {
		t.Fatalf("started %q", fixture.starts)
	}
	// The broker waits on and ends its helper.
	if state, err := windows.WaitForSingleObject(process, 10_000); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatal("the helper handle cannot be waited on:", state, err)
	}
	if _, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "clearGuard"}); err != nil || fixture.cleared != 1 {
		t.Fatal("Repair's guard clear was not served:", err, fixture.cleared)
	}
}

// Only the accounts an administrator allowed may ask; others are refused before
// anything starts, whether the pipe's DACL or the account check stops them.
func TestVPNServiceRefusesOtherAccounts(t *testing.T) {
	fixture := startServiceFixture(t, []string{"S-1-5-32-546"}, ownDigest(t))
	if _, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "start", Pipe: testVPNPipe}); err == nil {
		t.Fatal("an account that is not allowed started the helper")
	}
	if len(fixture.starts) != 0 {
		t.Fatal("the helper started for an account that is not allowed")
	}
}

// Another build's broker gets service_outdated, which sends it to the consent
// prompt; that prompt's helper install points the service at the new build.
func TestVPNServiceSendsAnotherBuildToConsent(t *testing.T) {
	fixture := startServiceFixture(t, []string{currentUserSID(t)}, strings.Repeat("0", 64))
	_, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "start", Pipe: testVPNPipe})
	if err == nil || err.Error() != "vpn_service_outdated" || len(fixture.starts) != 0 {
		t.Fatal("another build was served:", err, fixture.starts)
	}
}

// The helper's arguments come only from a pipe name of the broker's own form.
func TestVPNServiceRejectsOtherPipeNames(t *testing.T) {
	fixture := startServiceFixture(t, []string{currentUserSID(t)}, ownDigest(t))
	for _, pipe := range []string{`\\.\pipe\other`, vpnPipePrefix + "x", testVPNPipe + " --install-helper", ""} {
		if _, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "start", Pipe: pipe}); err == nil {
			t.Fatalf("pipe %q was accepted", pipe)
		}
	}
	if _, err := askServicePipe(fixture.name, windows.GetCurrentProcessId(), serviceRequest{Action: "install"}); err == nil {
		t.Fatal("an unknown action was accepted")
	}
	if len(fixture.starts) != 0 {
		t.Fatal("the helper started for a rejected request:", fixture.starts)
	}
}

// A same-user program could create the service's pipe name before the service
// does; the broker sends nothing to a server that is not the service process.
func TestVPNServiceClientRefusesAnotherServer(t *testing.T) {
	fixture := startServiceFixture(t, []string{currentUserSID(t)}, ownDigest(t))
	_, err := askServicePipe(fixture.name, windows.GetCurrentProcessId()+1, serviceRequest{Action: "start", Pipe: testVPNPipe})
	if err == nil || len(fixture.starts) != 0 {
		t.Fatal("the broker asked a server that is not the service:", err, fixture.starts)
	}
}

// Without the service, or for an account it does not allow, the broker learns
// so at once and asks for consent as before.
func TestVPNServiceAbsenceIsReportedAtOnce(t *testing.T) {
	started := time.Now()
	if _, err := vpnServiceProcess("ElarniVPN-test-missing"); !errors.Is(err, errVPNServiceUnavailable) {
		t.Fatal("a missing service reported", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("finding no service took", time.Since(started))
	}
}

// The allowed accounts live in the service's own command line, which only
// administrators can change and every user can read.
func TestVPNServiceUsersComeFromItsCommandLine(t *testing.T) {
	line := `"C:\Program Files\Elarni VPN Helper\0123456789abcdef\elarni-core.exe" --service S-1-5-21-1-2-3-1001,S-1-5-21-1-2-3-1002`
	if users := serviceCommandUsers(line); strings.Join(users, " ") != "S-1-5-21-1-2-3-1001 S-1-5-21-1-2-3-1002" {
		t.Fatalf("users %q", users)
	}
	if users := serviceCommandUsers(`"C:\Program Files\Elarni VPN Helper\0123456789abcdef\elarni-core.exe"`); users != nil {
		t.Fatalf("users %q", users)
	}
}

// Account changes arrive through a consent prompt from an unelevated caller;
// only well-formed SIDs reach the service's command line and DACL.
func TestVPNServiceUserChangesKeepCanonicalSIDs(t *testing.T) {
	users, err := changeServiceUsers([]string{"S-1-5-21-1-2-3-1002"}, true, "S-1-5-21-1-2-3-1001")
	if err != nil || strings.Join(users, " ") != "S-1-5-21-1-2-3-1001 S-1-5-21-1-2-3-1002" {
		t.Fatal(users, err)
	}
	if again, err := changeServiceUsers(users, true, "S-1-5-21-1-2-3-1001"); err != nil || len(again) != 2 {
		t.Fatal("adding an allowed account twice:", again, err)
	}
	if removed, err := changeServiceUsers(users, false, "S-1-5-21-1-2-3-1002"); err != nil || strings.Join(removed, " ") != "S-1-5-21-1-2-3-1001" {
		t.Fatal(removed, err)
	}
	// Group and well-known SIDs would let every account in.
	for _, bad := range []string{"", "S-1-x", "S-1-5-21-1)(A;;GA;;;WD", "S-1-5-21-1 --install-helper", "Everyone", "WD", "S-1-1-0", "S-1-5-11", "S-1-5-32-545"} {
		if _, err := changeServiceUsers(users, true, bad); err == nil {
			t.Fatalf("%q was accepted", bad)
		}
	}
	for _, sddl := range []string{vpnServicePipeSDDL(users), vpnServiceSDDL(users)} {
		if _, err := windows.SecurityDescriptorFromString(sddl); err != nil || !strings.Contains(sddl, "S-1-5-21-1-2-3-1001") {
			t.Fatalf("security descriptor %q: %v", sddl, err)
		}
	}
}
